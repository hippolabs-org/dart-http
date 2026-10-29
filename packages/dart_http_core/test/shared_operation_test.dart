import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_http_core/dart_http_core.dart';
import 'package:test/test.dart';

DartHttpClientOperationInfo info(String path) => DartHttpClientOperationInfo(
  operationId: path,
  kind: DartHttpClientOperationKind.http,
  pathTemplate: path,
  method: HttpMethod.post,
);
DartHttpClientEndpoint<String, Never, Never, Never, Map<String, Object?>> endpoint() =>
    DartHttpClientEndpoint<String, Never, Never, Never, Map<String, Object?>>(
      info: info('/body'),
      success: DartHttpClientResponseSpec<String>(
        status: 200,
        contentType: 'application/json',
        decoder: (value) => (value as Map)['answer'] as String,
      ),
      errors: const [DartHttpClientErrorSpec(status: 403, code: 'forbidden')],
      body: const DartHttpClientBodyCodec<Map<String, Object?>>(contentType: 'application/json'),
    );
void main() {
  test('endpoint error definitions cannot be mutated through shared lists', () {
    final errors = <DartHttpClientErrorSpec>[const DartHttpClientErrorSpec(status: 403)];
    final definition = DartHttpClientEndpoint<String, Never, Never, Never, Never>(
      info: info('/immutable'),
      success: endpoint().success,
      errors: errors,
    );
    errors.clear();
    expect(definition.errors.single.status, 403);
    expect(() => definition.errors.clear(), throwsUnsupportedError);
  });
  test('binds independent bodies and preserves metadata and default headers', () async {
    final transport = RecordingTransport();
    final operation = DartHttpJsonBodyOperation<Map<String, Object?>, String>(
      client: Client(transport),
      endpoint: endpoint(),
    );
    expect(transport.requests, isEmpty);
    expect(operation.info.pathTemplate, '/body');
    expect((await operation(body: {'value': 1})).requireData, 'ok');
    expect((await operation(body: {'value': 2})).requireData, 'ok');
    expect(transport.requests.map((r) => jsonDecode(r.body ?? utf8.decode(r.bodyBytes!))), [
      {'value': 1},
      {'value': 2},
    ]);
    expect(transport.requests.first.headers['x-client'], 'shared');
  });
  test('cancellation is per request and retains existing handle states', () async {
    final replies = <Completer<DartHttpClientResponse>>[];
    final sent = Completer<void>();
    final transport = RecordingTransport(
      onSend: (request) {
        final reply = Completer<DartHttpClientResponse>();
        replies.add(reply);
        unawaited(request.abortTrigger!.then((_) => reply.completeError(StateError('aborted'))));
        if (replies.length == 2) sent.complete();
        return reply.future;
      },
    );
    final operation = DartHttpJsonBodyOperation<Map<String, Object?>, String>(
      client: Client(transport),
      endpoint: endpoint(),
    );
    final first = operation.start(body: {'id': 1});
    final second = operation.start(body: {'id': 2});
    final canceled = expectLater(first.future, throwsStateError);
    await sent.future;
    first.cancel();
    replies.last.complete(jsonResponse());
    await canceled;
    expect((await second.future).requireData, 'ok');
    expect(first.state, DartHttpClientRequestState.canceled);
    expect(second.state, DartHttpClientRequestState.succeeded);
    expect(first.info, same(operation.info));
  });
  test('timeout aborts the transport and marks the started request timed out', () async {
    final transport = RecordingTransport(
      onSend: (request) async {
        await request.abortTrigger;
        throw StateError('aborted');
      },
    );
    final operation = DartHttpJsonBodyOperation<Map<String, Object?>, String>(
      client: Client(transport),
      endpoint: endpoint(),
    );
    final request = operation.start(body: {}, timeout: Duration.zero);
    await expectLater(request.future, throwsStateError);
    expect(request.state, DartHttpClientRequestState.timedOut);
    expect(request.endedAt, isNotNull);
  });
  test('documented HTTP errors stay response values and decoding errors throw', () async {
    final transport = RecordingTransport(
      onSend: (_) async => const DartHttpClientResponse(
        status: 403,
        contentType: 'application/json',
        body: '{"error":"denied"}',
      ),
    );
    final operation = DartHttpJsonBodyOperation<Map<String, Object?>, String>(
      client: Client(transport),
      endpoint: endpoint(),
    );
    final response = await operation(body: {});
    expect(response.error?.code, 'forbidden');
    expect(response.error?.kind, DartHttpClientErrorKind.documented);
    transport.onSend = (_) async =>
        const DartHttpClientResponse(status: 200, contentType: 'application/json', body: '{');
    await expectLater(operation(body: {}), throwsA(isA<FormatException>()));
  });
  test('optional queries are encoded and absent queries are omitted', () async {
    final transport = RecordingTransport();
    final operation = DartHttpJsonQueryOperation<Map<String, Object?>, String>(
      client: Client(transport),
      endpoint: DartHttpClientEndpoint<String, Never, Map<String, Object?>?, Never, Never>(
        info: info('/query'),
        success: endpoint().success,
        query: const DartHttpClientValueCodec<Map<String, Object?>?>(),
      ),
    );
    await operation();
    await operation(query: {'search': 'two words', 'page': 2});
    expect(transport.requests.first.uri.query, isEmpty);
    expect(transport.requests.last.uri.queryParameters, {'search': 'two words', 'page': '2'});
  });
  test('binary calls buffer bytes while stream calls preserve streaming delivery', () async {
    final transport = RecordingTransport(
      onSend: (_) async => DartHttpClientResponse(
        status: 200,
        contentType: 'application/octet-stream',
        bodyBytes: Uint8List.fromList([0, 255]),
      ),
    );
    final operation = DartHttpBinaryQueryOperation<Map<String, Object?>>(
      client: Client(transport),
      endpoint: DartHttpClientEndpoint<Uint8List, Never, Map<String, Object?>?, Never, Never>(
        info: info('/binary'),
        success: const DartHttpClientResponseSpec<Uint8List>(
          status: 200,
          contentType: 'application/octet-stream',
        ),
        query: const DartHttpClientValueCodec<Map<String, Object?>?>(),
      ),
    );
    expect((await operation()).requireData, [0, 255]);
    final response = await operation.stream(query: {'id': 'a'});
    expect(transport.streamRequests.single.uri.queryParameters, {'id': 'a'});
    expect(await response.bodyStream.toList(), [
      [1, 2],
      [3],
    ]);
    expect(transport.requests.length, 1);
  });
  test('multipart codec and progress reach the existing transport', () async {
    DartHttpMultipartUploadProgress? progress;
    final transport = RecordingTransport(
      onSend: (request) async {
        request.onUploadProgress!(
          const DartHttpClientUploadProgress(
            bytes: 1,
            totalBytes: 2,
            measurement: DartHttpClientUploadMeasurement.transportConsumed,
          ),
        );
        return jsonResponse();
      },
    );
    final operation = DartHttpMultipartJsonBodyOperation<MultipartFormData, String>(
      client: Client(transport),
      endpoint: DartHttpClientEndpoint<String, Never, Never, Never, MultipartFormData>(
        info: info('/upload'),
        success: endpoint().success,
        body: const DartHttpClientBodyCodec<MultipartFormData>(contentType: 'multipart/form-data'),
      ),
    );
    await operation(
      body: MultipartFormData(
        fields: const [MultipartFormField(name: 'name', value: 'value')],
        files: const [],
      ),
      onUploadProgress: (value) => progress = value,
    );
    expect(
      transport.requests.single.headers['content-type'],
      startsWith('multipart/form-data; boundary='),
    );
    expect(progress?.bytesSent, 1);
    expect(progress?.totalBytes, 2);
  });
  test('shared realtime operations bind queries, protocols and metadata', () async {
    final sockets = SocketTransport();
    final transports = SessionTransport();
    final client = Client(RecordingTransport(), sockets: sockets, sessions: transports);
    final socket = DartHttpWebSocketQueryOperation<Map<String, Object?>>(
      client: client,
      endpoint: const DartHttpClientConnectionEndpoint<Never, Map<String, Object?>?, Never>(
        info: DartHttpClientOperationInfo(
          operationId: 'socket',
          kind: DartHttpClientOperationKind.webSocket,
          pathTemplate: '/socket',
        ),
        query: DartHttpClientValueCodec<Map<String, Object?>?>(),
      ),
    );
    await socket.connect(query: {'ticket': 'a b'}, protocols: ['dictation']);
    expect(sockets.request!.uri.toString(), 'wss://example.test/socket?ticket=a+b');
    expect(sockets.request!.protocols, ['dictation']);
    expect(sockets.request!.headers['x-client'], 'shared');
    expect(socket.info.operationId, 'socket');
    final session = DartHttpWebTransportOperation(
      client: client,
      endpoint: const DartHttpClientConnectionEndpoint<Never, Never, Never>(
        info: DartHttpClientOperationInfo(
          operationId: 'transport',
          kind: DartHttpClientOperationKind.webTransport,
          pathTemplate: '/transport',
        ),
      ),
    );
    await session.connect();
    expect(transports.request!.uri.toString(), 'https://example.test/transport');
    expect(session.info.operationId, 'transport');
  });

  test('SSE start uses streaming transport and preserves the response body', () async {
    final transport = RecordingTransport();
    final operation = DartHttpSseOperation(
      client: Client(transport),
      endpoint: DartHttpClientEndpoint<Object?, Never, Never, Never, Never>(
        info: info('/events'),
        success: const DartHttpClientResponseSpec<Object?>(
          status: 200,
          contentType: 'text/event-stream',
          responseMode: DartHttpClientResponseMode.serverSentEvents,
        ),
      ),
    );
    final handle = operation.start();
    final response = await handle.future;
    expect(await response.bodyStream.toList(), [
      [1, 2],
      [3],
    ]);
    expect(transport.requests, isEmpty);
    expect(handle.state, DartHttpClientRequestState.succeeded);
  });
}

DartHttpClientResponse jsonResponse() => const DartHttpClientResponse(
  status: 200,
  contentType: 'application/json',
  body: '{"answer":"ok"}',
);

final class Client extends DartHttpClientBase {
  Client(
    HttpClientTransport transport, {
    DartHttpClientWebSocketTransport? sockets,
    DartHttpClientWebTransportTransport? sessions,
  }) : super(
         baseUri: Uri.parse('https://example.test'),
         transport: transport,
         defaultHeaders: const {'x-client': 'shared'},
         webSocketTransport: sockets,
         webTransportTransport: sessions,
       );
}

final class RecordingTransport implements HttpClientTransport {
  RecordingTransport({this.onSend});
  Future<DartHttpClientResponse> Function(DartHttpClientRequest)? onSend;
  final requests = <DartHttpClientRequest>[];
  final streamRequests = <DartHttpClientRequest>[];
  @override
  Future<DartHttpClientResponse> send(DartHttpClientRequest request) async {
    requests.add(request);
    return onSend == null ? jsonResponse() : onSend!(request);
  }

  @override
  Future<DartHttpClientStreamedResponse> sendStream(DartHttpClientRequest request) async {
    streamRequests.add(request);
    return DartHttpClientStreamedResponse(
      status: 200,
      contentType: request.uri.path == '/events' ? 'text/event-stream' : 'application/octet-stream',
      bodyStream: Stream<List<int>>.fromIterable([
        [1, 2],
        [3],
      ]),
    );
  }
}

final class SocketTransport implements DartHttpClientWebSocketTransport {
  DartHttpClientWebSocketRequest? request;
  @override
  Future<DartHttpClientWebSocket> connect(DartHttpClientWebSocketRequest request) async {
    this.request = request;
    return Socket();
  }
}

final class SessionTransport implements DartHttpClientWebTransportTransport {
  DartHttpClientWebTransportRequest? request;
  @override
  Future<DartHttpClientWebTransportSession> connect(
    DartHttpClientWebTransportRequest request,
  ) async {
    this.request = request;
    return Session();
  }
}

final class Socket implements DartHttpClientWebSocket {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class Session implements DartHttpClientWebTransportSession {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
