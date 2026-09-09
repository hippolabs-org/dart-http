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
    final firstBinary = Completer<WebSocketMessage>();
    final secondBinary = Completer<WebSocketMessage>();
    final thirdBinary = Completer<WebSocketMessage>();
    final subscription = socket.messages.listen((message) {
      switch (message.kind) {
        case WebSocketMessageKind.text:
          if (!text.isCompleted) text.complete(message);
        case WebSocketMessageKind.binary:
          if (!firstBinary.isCompleted) {
            firstBinary.complete(message);
          } else if (!secondBinary.isCompleted) {
            secondBinary.complete(message);
          } else if (!thirdBinary.isCompleted) {
            thirdBinary.complete(message);
          }
      }
    });
    addTearDown(subscription.cancel);
    addTearDown(socket.close);

    await socket.sendJson({'native': true});
    expect(jsonDecode((await text.future).text), {'native': true});

    await socket.sendBinary(<int>[1, 2, 3, 4]);
    final binaryMessage = await firstBinary.future;
    expect(binaryMessage.hasBinaryLease, isTrue);
    final lease = binaryMessage.takeBinaryLease();
    expect(lease.bytesView, <int>[1, 2, 3, 4]);
    await socket.sendBinaryLease(lease);
    expect(lease.isClosed, isTrue);

    final forwardedMessage = await secondBinary.future;
    final forwardedLease = forwardedMessage.takeBinaryLease();
    expect(forwardedLease.bytesView, <int>[1, 2, 3, 4]);
    await socket.sendBinaryLease(forwardedLease, prefix: const <int>[9, 8]);
    expect(forwardedLease.isClosed, isTrue);

    final prefixedMessage = await thirdBinary.future;
    final prefixedLease = prefixedMessage.takeBinaryLease();
    expect(prefixedLease.bytesView, <int>[9, 8, 1, 2, 3, 4]);
    prefixedLease.close();
  });

  test('base64-encodes an adopted native lease into one text message', () async {
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket
        ..listen(socket.add)
        ..add(<int>[99, 1, 2, 3, 4, 88]);
    });

    final socket = await transport.connect(
      DartHttpClientWebSocketRequest(
        uri: Uri.parse('ws://${server.address.host}:${server.port}/base64'),
      ),
    );
    addTearDown(socket.close);
    final binary = Completer<WebSocketMessage>();
    final text = Completer<WebSocketMessage>();
    final subscription = socket.messages.listen((message) {
      switch (message.kind) {
        case WebSocketMessageKind.text:
          text.complete(message);
        case WebSocketMessageKind.binary:
          binary.complete(message);
      }
    });
    addTearDown(subscription.cancel);

    final lease = (await binary.future).takeBinaryLease();
    await socket.sendTextBase64Lease(
      lease,
      prefix: '{"audio":"',
      suffix: '"}',
      offset: 1,
      length: 4,
    );

    expect(lease.isClosed, isTrue);
    expect(jsonDecode((await text.future).text), <String, Object?>{
      'audio': base64Encode(<int>[1, 2, 3, 4]),
    });
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

  test('delivers buffered frames before an immediate peer close', () async {
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket
        ..add('first')
        ..add(<int>[1, 2, 3]);
      await socket.close();
    });
    final socket = await transport.connect(
      DartHttpClientWebSocketRequest(
        uri: Uri.parse('ws://${server.address.host}:${server.port}/immediate-close'),
      ),
    );
    addTearDown(socket.close);

    await Future<void>.delayed(const Duration(milliseconds: 50));
    final messages = await socket.messages.toList().timeout(const Duration(seconds: 5));
    expect(messages, hasLength(2));
    expect(messages.first.text, 'first');
    final binary = messages.last.takeBinaryLease();
    expect(binary.bytesView, <int>[1, 2, 3]);
    binary.close();
  });

  test('enqueues native leases and flushes one ordered fence', () async {
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen(socket.add);
    });
    final socket = await transport.connect(
      DartHttpClientWebSocketRequest(
        uri: Uri.parse('ws://${server.address.host}:${server.port}/queued'),
      ),
    );
    addTearDown(socket.close);
    final queued = socket as DartHttpClientQueuedWebSocket;

    final received = Completer<WebSocketMessage>();
    final forwarded = Completer<WebSocketMessage>();
    final subscription = socket.messages.listen((message) {
      if (!received.isCompleted) {
        received.complete(message);
      } else {
        forwarded.complete(message);
      }
    });
    addTearDown(subscription.cancel);
    await socket.sendBinary(const <int>[1, 2, 3, 4]);
    final source = (await received.future).takeBinaryLease();
    final byteLease = switch (source) {
      NativeExchangeBinaryPayloadLease(lease: final value) => value,
      _ => throw StateError('Expected a Native Exchange lease.'),
    };

    queued.enqueueByteLease(byteLease, prefix: const <int>[9, 8]);
    expect(source.isClosed, isTrue);
    await queued.flush();

    final result = (await forwarded.future).takeBinaryLease();
    expect(result.bytesView, const <int>[9, 8, 1, 2, 3, 4]);
    result.close();
  });

  test('rejects sends beyond the configured bounded queue', () async {
    transport.close();
    transport = await NativeHttpClientTransport.open(webSocketOutgoingCapacity: 1);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(<int>[9, 8, 7]);
      socket.listen((_) {});
    });
    final socket = await transport.connect(
      DartHttpClientWebSocketRequest(
        uri: Uri.parse('ws://${server.address.host}:${server.port}/bounded'),
      ),
    );
    addTearDown(socket.close);

    final received = Completer<WebSocketMessage>();
    final subscription = socket.messages.listen(received.complete);
    addTearDown(subscription.cancel);
    final lease = (await received.future).takeBinaryLease();

    final first = socket.sendText('first');
    await expectLater(
      socket.sendBinaryLease(lease),
      throwsA(
        isA<NativeHttpClientException>().having(
          (error) => error.message,
          'message',
          contains('queue is full'),
        ),
      ),
    );
    expect(lease.isClosed, isTrue);
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
