import 'dart:io';

import 'package:dart_http_core/dart_http_core.dart';
import 'package:dart_http_resumable_upload/dart_http_resumable_upload_io.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late FileSystemResumableUploadStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('http-uploads-');
    store = FileSystemResumableUploadStore(directory: root);
  });
  tearDown(() async => root.delete(recursive: true));

  test('recovers confirmed offsets and truncates an unconfirmed crashed suffix', () async {
    final upload = await store.create(length: 4, metadata: {'owner': 'one'});
    await store.append(
      id: upload.id,
      expectedOffset: 0,
      complete: false,
      content: ResumableUploadContent.buffered(Stream.value([1, 2]), length: 2),
    );
    await store.payloadFile(upload.id).writeAsBytes([9, 9], mode: FileMode.append, flush: true);
    final reopened = FileSystemResumableUploadStore(directory: root);
    expect((await reopened.read(upload.id))!.offset, 2);
    await reopened.append(
      id: upload.id,
      expectedOffset: 2,
      complete: true,
      content: ResumableUploadContent.buffered(Stream.value([3, 4]), length: 2),
    );
    expect(await reopened.payloadFile(upload.id).readAsBytes(), [1, 2, 3, 4]);
  });

  test('retains a durable prefix after a broken request stream', () async {
    final upload = await store.create(length: 4, metadata: {});
    await expectLater(
      store.append(
        id: upload.id,
        expectedOffset: 0,
        complete: true,
        content: ResumableUploadContent.buffered(() async* {
          yield [1, 2];
          throw StateError('disconnect');
        }(), length: 4),
      ),
      throwsStateError,
    );
    expect((await FileSystemResumableUploadStore(directory: root).read(upload.id))!.offset, 2);
  });

  test('serializes separate store instances and rejects stale appends', () async {
    final upload = await store.create(length: 2, metadata: {});
    final other = FileSystemResumableUploadStore(
      directory: Directory(
        '${root.path}/../${root.uri.pathSegments.where((s) => s.isNotEmpty).last}',
      ),
    );
    final first = store.append(
      id: upload.id,
      expectedOffset: 0,
      complete: false,
      content: ResumableUploadContent.buffered(Stream.value([1]), length: 1),
    );
    final stale = other.append(
      id: upload.id,
      expectedOffset: 0,
      complete: false,
      content: ResumableUploadContent.buffered(Stream.value([9]), length: 1),
    );
    await expectLater(stale, throwsA(isA<ResumableUploadOffsetMismatchException>()));
    await first;
    expect(await store.payloadFile(upload.id).readAsBytes(), [1]);
  });

  test('persists finalization results across instances and retries failures', () async {
    final upload = await store.create(length: 0, metadata: {});
    await store.append(
      id: upload.id,
      expectedOffset: 0,
      complete: true,
      content: ResumableUploadContent.buffered(const Stream.empty(), length: 0),
    );
    await expectLater(store.finalize(upload.id, () => throw StateError('retry')), throwsStateError);
    await store
        .finalize(upload.id, () async {
          // Application finalizers inspect the completed upload themselves.
          expect((await store.read(upload.id))!.complete, isTrue);
          return RawResponse.json(status: 200, body: {'id': 'one'});
        })
        .timeout(const Duration(seconds: 2));
    final response = await FileSystemResumableUploadStore(directory: root)
        .finalize(upload.id, () => throw StateError('must replay'));
    expect(response.body, {'id': 'one'});
  });

  test('expires and removes payloads and rejects path traversal', () async {
    var time = DateTime.utc(2026);
    store = FileSystemResumableUploadStore(directory: root, clock: () => time);
    final upload = await store.create(length: 0, metadata: {}, maxAge: const Duration(seconds: 1));
    time = time.add(const Duration(seconds: 2));
    expect(await store.read(upload.id), isNull);
    expect(await store.deleteExpired(), 1);
    expect(await store.payloadFile(upload.id).exists(), isFalse);
    expect(() => store.payloadFile('../escape'), throwsArgumentError);
  });

  test('router extension can require pre-authorized session creation', () {
    final router = Router<void>();
    router.resumableUploads(
      path: '/uploads',
      store: store,
      allowCreation: false,
      locationFor: (_, r) => Uri.parse('https://test/uploads/${r.id}'),
    );
    expect(
      router.routeRegistry.registrations.where((r) => r.httpMethod == HttpMethod.post),
      isEmpty,
    );
    expect(router.routeRegistry.registrations, hasLength(4));
  });
}
