import 'dart:typed_data';

import 'package:dart_http_core/dart_http_core.dart';
import 'package:dart_http_resumable_upload/dart_http_resumable_upload.dart';
import 'package:test/test.dart';

void main() {
  test('mounts discover, create, inspect, append, and cancel routes', () {
    final router = Router<void>();

    mountResumableUploadRoutes<void>(
      router,
      path: '/uploads',
      store: InMemoryResumableUploadStore(idGenerator: () => 'one'),
      locationFor: (_, resource) => Uri.parse('https://example.test/uploads/${resource.id}'),
    );

    expect(
      router.routeRegistry.registrations.map(
        (registration) => (registration.httpMethod, registration.httpPath),
      ),
      [
        (HttpMethod.options, '/uploads'),
        (HttpMethod.post, '/uploads'),
        (HttpMethod.head, '/uploads/<uploadId>'),
        (HttpMethod.patch, '/uploads/<uploadId>'),
        (HttpMethod.delete, '/uploads/<uploadId>'),
      ],
    );
    final append = router.routeRegistry.registrations.firstWhere(
      (registration) => registration.httpMethod == HttpMethod.patch,
    );
    expect(
      (append.route as HttpRouteDefinition<void, RawResponse>).options.body?.delivery,
      RequestBodyDelivery.buffered,
    );
  });

  test('uses native request streaming for native-capable stores', () {
    final router = Router<void>();
    mountResumableUploadRoutes<void>(
      router,
      path: '/uploads',
      store: _NativeTestStore(),
      locationFor: (_, resource) => Uri.parse('https://example.test/uploads/${resource.id}'),
    );

    final append = router.routeRegistry.registrations.firstWhere(
      (registration) => registration.httpMethod == HttpMethod.patch,
    );
    expect(
      (append.route as HttpRouteDefinition<void, RawResponse>).options.body?.delivery,
      RequestBodyDelivery.nativeStream,
    );
  });

  test('accepts sequential chunks and invokes completion once', () async {
    final router = Router<void>();
    final store = InMemoryResumableUploadStore(idGenerator: () => 'one');
    var completionCount = 0;
    mountResumableUploadRoutes<void>(
      router,
      path: '/uploads',
      store: store,
      limits: const ResumableUploadLimits(maxAppendSize: 3),
      locationFor: (_, resource) => Uri.parse('https://example.test/uploads/${resource.id}'),
      onCompleted: (_, resource) {
        completionCount += 1;
        return RawResponse.json(status: 200, body: <String, Object?>{'id': resource.id});
      },
    );

    final created = await _handle(
      router,
      HttpMethod.post,
      RequestInput(
        headersMap: <String, String>{
          ResumableUploadProtocol.draftInteropVersionHeader:
              '${ResumableUploadProtocol.draftInteropVersion}',
          ResumableUploadProtocol.lengthHeader: '5',
          ResumableUploadProtocol.completeHeader: '?0',
        },
      ),
    );
    expect(created.status, 201);
    expect(_header(created, 'location'), 'https://example.test/uploads/one');

    final first = await _handle(
      router,
      HttpMethod.patch,
      _appendRequest(offset: 0, complete: false, bytes: <int>[1, 2, 3]),
    );
    expect(first.status, 204);
    expect(_header(first, 'upload-offset'), '3');

    final inspected = await _handle(router, HttpMethod.head, _resourceRequest());
    expect(inspected.status, 204);
    expect(_header(inspected, 'upload-offset'), '3');
    expect(_header(inspected, 'upload-complete'), '?0');

    final completed = await _handle(
      router,
      HttpMethod.patch,
      _appendRequest(offset: 3, complete: true, bytes: <int>[4, 5]),
    );
    expect(completed.status, 200);
    expect(_header(completed, 'upload-offset'), '5');
    expect(_header(completed, 'upload-complete'), '?1');
    expect(completionCount, 1);
    expect(await store.bytesFor('one'), <int>[1, 2, 3, 4, 5]);
  });

  test('rejects a stale offset without corrupting stored bytes', () async {
    final store = InMemoryResumableUploadStore(idGenerator: () => 'one');
    await store.create(length: 4, metadata: const <String, String>{});
    await store.append(
      id: 'one',
      expectedOffset: 0,
      content: ResumableUploadContent.buffered(Stream<List<int>>.value(<int>[1, 2]), length: 2),
      complete: false,
    );

    await expectLater(
      store.append(
        id: 'one',
        expectedOffset: 0,
        content: ResumableUploadContent.buffered(Stream<List<int>>.value(<int>[9, 9]), length: 2),
        complete: false,
      ),
      throwsA(isA<ResumableUploadOffsetMismatchException>()),
    );
    expect(await store.bytesFor('one'), <int>[1, 2]);
  });
}

RequestInput _resourceRequest() => RequestInput(
  paramsMap: const <String, String>{'uploadId': 'one'},
  headersMap: <String, String>{
    ResumableUploadProtocol.draftInteropVersionHeader:
        '${ResumableUploadProtocol.draftInteropVersion}',
  },
);

RequestInput _appendRequest({
  required int offset,
  required bool complete,
  required List<int> bytes,
}) => RequestInput(
  paramsMap: const <String, String>{'uploadId': 'one'},
  headersMap: <String, String>{
    'content-type': ResumableUploadProtocol.partialUploadMediaType,
    ResumableUploadProtocol.draftInteropVersionHeader:
        '${ResumableUploadProtocol.draftInteropVersion}',
    ResumableUploadProtocol.offsetHeader: '$offset',
    ResumableUploadProtocol.lengthHeader: '5',
    ResumableUploadProtocol.completeHeader: ResumableUploadProtocol.encodeBoolean(complete),
  },
  body: Uint8List.fromList(bytes),
);

Future<RawResponse> _handle(Router<void> router, HttpMethod method, RequestInput request) async {
  final registration = router.routeRegistry.registrations.firstWhere(
    (registration) => registration.httpMethod == method,
  );
  final route = registration.route as HttpRouteDefinition<void, RawResponse>;
  return route.handle(RequestContext<void>(services: null, req: request));
}

String? _header(RawResponse response, String name) {
  final normalized = name.toLowerCase();
  for (final header in response.headers) {
    if (header.name.toLowerCase() == normalized) return header.value;
  }
  return null;
}

final class _NativeTestStore implements NativeResumableUploadStore {
  final _delegate = InMemoryResumableUploadStore(idGenerator: () => 'native');

  @override
  Future<ResumableUploadResource> append({
    required String id,
    required int expectedOffset,
    required ResumableUploadContent content,
    required bool complete,
  }) => _delegate.append(
    id: id,
    expectedOffset: expectedOffset,
    content: content,
    complete: complete,
  );

  @override
  Future<void> cancel(String id) => _delegate.cancel(id);

  @override
  Future<ResumableUploadResource> create({
    required int length,
    required Map<String, String> metadata,
    Duration? maxAge,
  }) => _delegate.create(length: length, metadata: metadata, maxAge: maxAge);

  @override
  Future<ResumableUploadResource?> read(String id) => _delegate.read(id);
}
