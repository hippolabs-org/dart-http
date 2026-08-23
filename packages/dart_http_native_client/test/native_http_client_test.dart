import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_http_core/dart_http_core.dart';
import 'package:dart_http_native_client/dart_http_native_client.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late NativeHttpClientTransport transport;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    transport = await NativeHttpClientTransport.open();
  });

  tearDown(() async {
    transport.close();
    await server.close(force: true);
  });

  test('sends bytes and buffers a native response', () async {
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'received': body}));
      await request.response.close();
    });

    final response = await transport.send(
      DartHttpClientRequest(
        method: HttpMethod.post,
        uri: Uri.parse('http://${server.address.host}:${server.port}/echo'),
        headers: const {'content-type': 'text/plain'},
        body: 'native request',
      ),
    );

    expect(response.status, HttpStatus.ok);
    expect(response.contentType, contains('application/json'));
    expect(jsonDecode(response.body), {'received': 'native request'});
  });

  test('streams a native response through the compatibility byte stream', () async {
    server.listen((request) async {
      request.response
        ..headers.contentType = ContentType.text
        ..write('first-');
      await request.response.flush();
      request.response.write('second');
      await request.response.close();
    });

    final response = await transport.sendStream(
      DartHttpClientRequest(
        method: HttpMethod.get,
        uri: Uri.parse('http://${server.address.host}:${server.port}/stream'),
      ),
    );
    final body = await utf8.decoder.bind(response.bodyStream).join();

    expect(response.status, HttpStatus.ok);
    expect(body, 'first-second');
  });

  test('cancels an in-flight Tokio request', () async {
    final requestStarted = Completer<void>();
    server.listen((request) async {
      requestStarted.complete();
      await Future<void>.delayed(const Duration(seconds: 5));
      await request.response.close();
    });
    final abort = Completer<void>();
    final response = transport.send(
      DartHttpClientRequest(
        method: HttpMethod.get,
        uri: Uri.parse('http://${server.address.host}:${server.port}/slow'),
        abortTrigger: abort.future,
      ),
    );
    await requestStarted.future;
    abort.complete();

    await expectLater(response, throwsA(isA<NativeHttpClientException>()));
  });

  test('negotiates native WebSockets and leases binary frames', () async {
    server.listen((request) async {
      expect(request.headers.value('x-native-test'), 'enabled');
      final socket = await WebSocketTransformer.upgrade(
        request,
        protocolSelector: (protocols) => protocols.contains('native-v1') ? 'native-v1' : null,
      );
      socket.listen(socket.add);
    });

    final socket = await transport.connect(
      DartHttpClientWebSocketRequest(
        uri: Uri.parse('ws://${server.address.host}:${server.port}/native'),
        headers: const {'x-native-test': 'enabled'},
        protocols: const ['native-v1'],
      ),
    );
    final nativeSocket = socket as NativeHttpWebSocket;
    expect(nativeSocket.selectedProtocol, 'native-v1');

    final text = Completer<WebSocketMessage>();
    final binary = Completer<WebSocketMessage>();
    final subscription = socket.messages.listen((message) {
      switch (message.kind) {
        case WebSocketMessageKind.text:
          if (!text.isCompleted) text.complete(message);
        case WebSocketMessageKind.binary:
          if (!binary.isCompleted) binary.complete(message);
      }
    });
    addTearDown(subscription.cancel);
    addTearDown(socket.close);

    await socket.sendJson({'native': true});
    expect(jsonDecode((await text.future).text), {'native': true});

    await socket.sendBinary(<int>[1, 2, 3, 4]);
    final binaryMessage = await binary.future;
    expect(binaryMessage.hasBinaryLease, isTrue);
    final lease = binaryMessage.takeBinaryLease();
    expect(lease.bytesView, <int>[1, 2, 3, 4]);
    lease.close();
    expect(lease.isClosed, isTrue);
  });

  test('bounds native receive work while the Dart subscription is paused', () async {
    transport.close();
    transport = await NativeHttpClientTransport.open(webSocketIncomingCapacity: 2);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      for (var index = 0; index < 32; index++) {
        socket.add(List<int>.filled(64 * 1024, index));
      }
    });
    final socket = await transport.connect(
      DartHttpClientWebSocketRequest(
        uri: Uri.parse('ws://${server.address.host}:${server.port}/slow'),
      ),
    );
    addTearDown(socket.close);

    final completed = Completer<void>();
    var received = 0;
    final subscription = socket.messages.listen((message) {
      final lease = message.takeBinaryLease();
      expect(lease.length, 64 * 1024);
      lease.close();
      received++;
      if (received == 32) completed.complete();
    });
    addTearDown(subscription.cancel);
    subscription.pause();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(received, 0);
    subscription.resume();
    await completed.future.timeout(const Duration(seconds: 10));
  });

  test('rejects sends beyond the configured bounded queue', () async {
    transport.close();
    transport = await NativeHttpClientTransport.open(webSocketOutgoingCapacity: 1);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((_) {});
    });
    final socket = await transport.connect(
      DartHttpClientWebSocketRequest(
        uri: Uri.parse('ws://${server.address.host}:${server.port}/bounded'),
      ),
    );
    addTearDown(socket.close);

    final first = socket.sendText('first');
    await expectLater(
      socket.sendText('second'),
      throwsA(
        isA<NativeHttpClientException>().having(
          (error) => error.message,
          'message',
          contains('queue is full'),
        ),
      ),
    );
    await first;
  });

  test('closes without deadlock when the native receive queue is full', () async {
    transport.close();
    transport = await NativeHttpClientTransport.open(webSocketIncomingCapacity: 2);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      for (var index = 0; index < 64; index++) {
        socket.add(List<int>.filled(64 * 1024, index));
      }
    });
    final socket = await transport.connect(
      DartHttpClientWebSocketRequest(
        uri: Uri.parse('ws://${server.address.host}:${server.port}/close-full'),
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 100));
    await socket.close().timeout(const Duration(seconds: 5));
  });
}
