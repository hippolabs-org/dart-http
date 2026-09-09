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

  test('streams a Dart request body before its source completes', () async {
    final firstChunkReceived = Completer<void>();
    final releaseSecondChunk = Completer<void>();
    server.listen((request) async {
      final received = <int>[];
      await for (final chunk in request) {
        received.addAll(chunk);
        if (!firstChunkReceived.isCompleted) firstChunkReceived.complete();
      }
      request.response.add(received);
      await request.response.close();
    });

    final responseFuture = transport.send(
      DartHttpClientRequest(
        method: HttpMethod.post,
        uri: Uri.parse('http://${server.address.host}:${server.port}/stream-upload'),
        bodyStream: () async* {
          yield const <int>[1, 2, 3];
          await releaseSecondChunk.future;
          yield const <int>[4, 5, 6];
        }(),
        bodyStreamLength: 6,
      ),
    );

    await firstChunkReceived.future.timeout(const Duration(seconds: 5));
    releaseSecondChunk.complete();
    final response = await responseFuture.timeout(const Duration(seconds: 5));
    expect(response.bodyBytes, const <int>[1, 2, 3, 4, 5, 6]);
  });

  test('streams a Dart request body with unknown content length', () async {
    server.listen((request) async {
      final received = await request.fold<int>(0, (count, chunk) => count + chunk.length);
      request.response.write(received);
      await request.response.close();
    });

    final response = await transport.send(
      DartHttpClientRequest(
        method: HttpMethod.post,
        uri: Uri.parse('http://${server.address.host}:${server.port}/chunked-upload'),
        bodyStream: Stream<List<int>>.fromIterable(const <List<int>>[
          <int>[1, 2],
          <int>[3, 4, 5],
        ]),
      ),
    );

    expect(response.body, '5');
  });

  test('rejects a Dart request body that exceeds its declared length', () async {
    server.listen((request) async {
      await request.drain<void>();
      await request.response.close();
    });

    expect(
      transport.send(
        DartHttpClientRequest(
          method: HttpMethod.post,
          uri: Uri.parse('http://${server.address.host}:${server.port}/invalid-upload'),
          bodyStream: Stream<List<int>>.value(const <int>[1, 2, 3]),
          bodyStreamLength: 2,
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('exceeded its declared length'),
        ),
      ),
    );
  });

  test('cancels a streaming upload when its Dart source fails', () async {
    server.listen((request) async {
      await request.drain<void>();
      await request.response.close();
    });
    final source = StreamController<List<int>>();
    final responseFuture = transport.send(
      DartHttpClientRequest(
        method: HttpMethod.post,
        uri: Uri.parse('http://${server.address.host}:${server.port}/failed-upload'),
        bodyStream: source.stream,
      ),
    );
    source
      ..add(const <int>[1, 2, 3])
      ..addError(StateError('source failed'));
    await source.close();

    await expectLater(
      responseFuture,
      throwsA(isA<StateError>().having((error) => error.message, 'message', 'source failed')),
    );
  });

  test('cancels a dormant Dart body source when the request is aborted', () async {
    server.listen((request) async {
      await request.drain<void>();
      await request.response.close();
    });
    final sourceCanceled = Completer<void>();
    final source = StreamController<List<int>>(onCancel: () => sourceCanceled.complete());
    final abort = Completer<void>();
    final responseFuture = transport.send(
      DartHttpClientRequest(
        method: HttpMethod.post,
        uri: Uri.parse('http://${server.address.host}:${server.port}/aborted-upload'),
        bodyStream: source.stream,
        abortTrigger: abort.future,
      ),
    );
    source.add(const <int>[1, 2, 3]);
    abort.complete();

    await expectLater(responseFuture, throwsA(isA<NativeHttpClientException>()));
    await sourceCanceled.future.timeout(const Duration(seconds: 5));
    await source.close();
  });

  test('prewarms idempotently and reuses the process-wide connection pool', () async {
    await Future.wait([NativeHttpClientRuntime.prewarm(), NativeHttpClientRuntime.prewarm()]);
    final remotePorts = <int>[];
    server.listen((request) async {
      remotePorts.add(request.connectionInfo!.remotePort);
      request.response
        ..persistentConnection = true
        ..write('ok');
      await request.response.close();
    });
    final uri = Uri.parse('http://${server.address.host}:${server.port}/pooled');

    expect(
      (await transport.send(DartHttpClientRequest(method: HttpMethod.get, uri: uri))).body,
      'ok',
    );
    transport.close();
    transport = await NativeHttpClientTransport.open();
    expect(
      (await transport.send(DartHttpClientRequest(method: HttpMethod.get, uri: uri))).body,
      'ok',
    );

    expect(remotePorts, hasLength(2));
    expect(remotePorts[1], remotePorts[0]);
  });

  test('bounds process-wide HTTP startup concurrency', () async {
    const expectedLimit = 12;
    var activeRequests = 0;
    var maxActiveRequests = 0;
    final reachedLimit = Completer<void>();
    final releaseRequests = Completer<void>();
    server.listen((request) async {
      activeRequests++;
      if (activeRequests > maxActiveRequests) maxActiveRequests = activeRequests;
      if (activeRequests == expectedLimit && !reachedLimit.isCompleted) {
        reachedLimit.complete();
      }
      await releaseRequests.future;
      request.response.write('ok');
      await request.response.close();
      activeRequests--;
    });
    addTearDown(() {
      if (!releaseRequests.isCompleted) releaseRequests.complete();
    });
    final uri = Uri.parse('http://${server.address.host}:${server.port}/startup');
    final requests = List<Future<DartHttpClientResponse>>.generate(
      36,
      (_) => transport.send(DartHttpClientRequest(method: HttpMethod.get, uri: uri)),
    );

    await reachedLimit.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(maxActiveRequests, expectedLimit);

    releaseRequests.complete();
    final responses = await Future.wait(requests).timeout(const Duration(seconds: 10));
    expect(responses.every((response) => response.body == 'ok'), isTrue);
    expect(maxActiveRequests, expectedLimit);
  });

  test('keeps buffered response bytes native until explicitly materialized', () async {
    server.listen((request) async {
      request.response
        ..headers.set('x-native-metadata', 'typed')
        ..add(const [1, 2, 3, 4]);
      await request.response.close();
    });

    final response = await transport.sendLeased(
      DartHttpClientRequest(
        method: HttpMethod.get,
        uri: Uri.parse('http://${server.address.host}:${server.port}/leased'),
      ),
    );

    expect(response.headers['x-native-metadata'], 'typed');
    expect(response.body.bytesView, const [1, 2, 3, 4]);
    expect(response.body.isClosed, isFalse);
    response.close();
    expect(response.body.isClosed, isTrue);
  });

  test('materializes compatibility response bytes once', () async {
    server.listen((request) async {
      request.response.add(const [4, 3, 2, 1]);
      await request.response.close();
    });

    final response = await transport.send(
      DartHttpClientRequest(
        method: HttpMethod.get,
        uri: Uri.parse('http://${server.address.host}:${server.port}/compatibility'),
      ),
    );
    final first = response.bodyBytes;
    final second = response.bodyBytes;

    expect(first, const [4, 3, 2, 1]);
    expect(identical(first, second), isTrue);
  });

  test('transfers a native response lease into a request without Dart bytes', () async {
    server.listen((request) async {
      if (request.uri.path == '/source') {
        request.response.add(const [8, 6, 7, 5, 3, 0, 9]);
      } else {
        request.response.add(
          await request.fold<List<int>>(<int>[], (all, bytes) => all..addAll(bytes)),
        );
      }
      await request.response.close();
    });
    final base = 'http://${server.address.host}:${server.port}';
    final source = await transport.sendLeased(
      DartHttpClientRequest(method: HttpMethod.get, uri: Uri.parse('$base/source')),
    );

    final echoed = await transport.send(
      DartHttpClientRequest(
        method: HttpMethod.post,
        uri: Uri.parse('$base/echo'),
        bodyLease: source.body,
      ),
    );

    expect(source.body.isClosed, isTrue);
    expect(echoed.bodyBytes, const [8, 6, 7, 5, 3, 0, 9]);
  });

  test('buffers concurrent immediate responses without losing completion', () async {
    server.listen((request) async {
      final index = request.uri.queryParameters['index'];
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'index': index}));
      await request.response.close();
    });

    for (var batch = 0; batch < 20; batch++) {
      final responses = await Future.wait([
        for (var index = 0; index < 32; index++)
          transport
              .send(
                DartHttpClientRequest(
                  method: HttpMethod.get,
                  uri: Uri.parse(
                    'http://${server.address.host}:${server.port}/fast'
                    '?index=$batch-$index',
                  ),
                ),
              )
              .timeout(const Duration(seconds: 5)),
      ]);

      for (var index = 0; index < responses.length; index++) {
        expect(jsonDecode(responses[index].body), {'index': '$batch-$index'});
      }
    }
  });

  test('receives concurrent immediate response metadata', () async {
    server.listen((request) async {
      request.response.write('ok');
      await request.response.close();
    });

    final responses = await Future.wait([
      for (var index = 0; index < 64; index++)
        transport
            .sendNative(
              DartHttpClientRequest(
                method: HttpMethod.get,
                uri: Uri.parse('http://${server.address.host}:${server.port}/fast/$index'),
              ),
            )
            .timeout(const Duration(seconds: 5)),
    ]);
    for (final response in responses) {
      response.body.close();
    }
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

  test('streams response chunks as zero-copy native leases', () async {
    final releaseSecondChunk = Completer<void>();
    addTearDown(() {
      if (!releaseSecondChunk.isCompleted) releaseSecondChunk.complete();
    });
    server.listen((request) async {
      request.response.bufferOutput = false;
      request.response.write('first');
      await request.response.flush();
      await releaseSecondChunk.future;
      request.response.write('second');
      await request.response.close();
    });

    final response = await transport.sendLeasedStream(
      DartHttpClientRequest(
        method: HttpMethod.get,
        uri: Uri.parse('http://${server.address.host}:${server.port}/leased-stream'),
      ),
    );
    final iterator = StreamIterator(response.bodyStream);
    addTearDown(iterator.cancel);

    expect(await iterator.moveNext(), isTrue);
    final first = iterator.current;
    expect(utf8.decode(first.bytesView), 'first');
    expect(first.isClosed, isFalse);
    first.close();
    expect(first.isClosed, isTrue);

    releaseSecondChunk.complete();
    expect(await iterator.moveNext(), isTrue);
    final second = iterator.current;
    expect(utf8.decode(second.bytesView), 'second');
    second.close();
    expect(await iterator.moveNext(), isFalse);
  });

  test('closes a leased stream before it is listened to', () async {
    server.listen((request) async {
      request.response.bufferOutput = false;
      request.response.write('first');
      await request.response.flush();
      await Future<void>.delayed(const Duration(seconds: 30));
    });

    final response = await transport.sendLeasedStream(
      DartHttpClientRequest(
        method: HttpMethod.get,
        uri: Uri.parse('http://${server.address.host}:${server.port}/abandoned-stream'),
      ),
    );

    await response.close().timeout(const Duration(seconds: 5));
    await response.close();
    expect(response.bodyStream.listen(null).asFuture<void>(), completes);
  });

  test('closes an unconsumed native response idempotently', () async {
    server.listen((request) async {
      request.response.write('native body');
      await request.response.close();
    });

    final response = await transport.sendNative(
      DartHttpClientRequest(
        method: HttpMethod.get,
        uri: Uri.parse('http://${server.address.host}:${server.port}/native-close'),
      ),
    );

    await response.close();
    await response.close();
  });

  test('delivers a flushed SSE event before the response finishes', () async {
    final releaseSecondEvent = Completer<void>();
    addTearDown(() {
      if (!releaseSecondEvent.isCompleted) releaseSecondEvent.complete();
    });
    server.listen((request) async {
      request.response.bufferOutput = false;
      request.response.headers
        ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
        ..set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.response.write('data: first\n\n');
      await request.response.flush();
      await releaseSecondEvent.future;
      request.response.write('data: second\n\n');
      await request.response.close();
    });

    final response = await transport.sendStream(
      DartHttpClientRequest(
        method: HttpMethod.get,
        uri: Uri.parse('http://${server.address.host}:${server.port}/events'),
        headers: const {'accept': 'text/event-stream'},
      ),
    );
    final firstEvent = Completer<String>();
    final body = StringBuffer();
    final subscription = utf8.decoder.bind(response.bodyStream).listen((chunk) {
      body.write(chunk);
      if (!firstEvent.isCompleted && body.toString().contains('\n\n')) {
        firstEvent.complete(body.toString());
      }
    });
    addTearDown(subscription.cancel);

    expect(
      await firstEvent.future.timeout(const Duration(seconds: 1)),
      contains('data: first\n\n'),
    );
    releaseSecondEvent.complete();
    await subscription.asFuture<void>();
    expect(body.toString(), 'data: first\n\ndata: second\n\n');
  });

  test('cancels an idle direct response reader without hanging', () async {
    final keepOpen = Completer<void>();
    addTearDown(() {
      if (!keepOpen.isCompleted) keepOpen.complete();
    });
    server.listen((request) async {
      request.response.bufferOutput = false;
      request.response.write('data: ready\n\n');
      await request.response.flush();
      await keepOpen.future;
      await request.response.close();
    });

    final response = await transport.sendStream(
      DartHttpClientRequest(
        method: HttpMethod.get,
        uri: Uri.parse('http://${server.address.host}:${server.port}/idle-events'),
      ),
    );
    final firstEvent = Completer<void>();
    final subscription = response.bodyStream.listen((chunk) {
      if (utf8.decode(chunk).contains('ready') && !firstEvent.isCompleted) {
        firstEvent.complete();
      }
    });

    await firstEvent.future.timeout(const Duration(seconds: 1));
    await subscription.cancel().timeout(const Duration(seconds: 1));
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

  test('exposes the peer WebSocket close code and reason', () async {
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      await socket.close(1008, 'Session revoked');
    });

    final socket = await transport.connect(
      DartHttpClientWebSocketRequest(
        uri: Uri.parse('ws://${server.address.host}:${server.port}/native-close'),
      ),
    );
    final nativeSocket = socket as NativeHttpWebSocket;

    await socket.messages.drain<void>();

    expect(
      nativeSocket.closeDetails,
      isA<DartHttpClientWebSocketCloseDetails>()
          .having((details) => details.code, 'code', 1008)
          .having((details) => details.reason, 'reason', 'Session revoked'),
    );
  });

  test('reports a WebSocket opening failure only through connect', () async {
    final resetServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var acceptedConnections = 0;
    final resetSubscription = resetServer.listen((socket) {
      acceptedConnections++;
      socket.destroy();
    });
    addTearDown(() async {
      await resetSubscription.cancel();
      await resetServer.close();
    });
    final uncaughtErrors = <Object>[];

    await runZonedGuarded<Future<void>>(() async {
      await expectLater(
        transport.connect(
          DartHttpClientWebSocketRequest(
            uri: Uri.parse(
              'ws://${resetServer.address.host}:${resetServer.port}/reset-during-opening',
            ),
          ),
        ),
        throwsA(isA<NativeHttpClientException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }, (error, _) => uncaughtErrors.add(error));

    expect(uncaughtErrors, isEmpty);
    expect(acceptedConnections, 1);
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

  test('enqueues native base64 text without a per-message completion', () async {
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen(socket.add);
    });
    final socket = await transport.connect(
      DartHttpClientWebSocketRequest(
        uri: Uri.parse('ws://${server.address.host}:${server.port}/queued-base64'),
      ),
    );
    addTearDown(socket.close);
    final queued = socket as DartHttpClientQueuedWebSocket;

    final first = Completer<WebSocketMessage>();
    final second = Completer<WebSocketMessage>();
    final subscription = socket.messages.listen((message) {
      if (!first.isCompleted) {
        first.complete(message);
      } else {
        second.complete(message);
      }
    });
    addTearDown(subscription.cancel);
    await socket.sendBinary(const <int>[0, 1, 2, 3, 4, 5]);
    final source = (await first.future).takeBinaryLease();

    queued.enqueueTextBase64Lease(source, prefix: '{"audio":"', suffix: '"}', offset: 1, length: 4);
    expect(source.isClosed, isTrue);
    await queued.flush();

    expect((await second.future).text, '{"audio":"${base64Encode(const <int>[1, 2, 3, 4])}"}');
  });

  test('pumps a native byte stream into base64 text frames', () async {
    final sourceBytes = <int>[for (var index = 0; index < 256 * 1024; index++) index & 0xff];
    final receivedBytes = <int>[];
    final receivedAll = Completer<void>();
    final allowSourceEof = Completer<void>();
    server.listen((request) async {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((message) {
          final text = message as String;
          expect(text, startsWith('{"audio":"'));
          expect(text, endsWith('"}'));
          receivedBytes.addAll(base64Decode(text.substring(10, text.length - 2)));
          if (receivedBytes.length >= sourceBytes.length && !receivedAll.isCompleted) {
            receivedAll.complete();
          }
        });
        return;
      }
      for (var offset = 0; offset < sourceBytes.length; offset += 16 * 1024) {
        request.response.add(sourceBytes.sublist(offset, offset + 16 * 1024));
        await request.response.flush();
      }
      await allowSourceEof.future;
      await request.response.close();
    });
    final socket = await transport.connect(
      DartHttpClientWebSocketRequest(
        uri: Uri.parse('ws://${server.address.host}:${server.port}/base64-pump'),
      ),
    );
    addTearDown(socket.close);
    final source = await transport.sendNative(
      DartHttpClientRequest(
        method: HttpMethod.get,
        uri: Uri.parse('http://${server.address.host}:${server.port}/audio'),
      ),
    );
    final pump = (socket as DartHttpClientNativeStreamWebSocket).adoptBase64TextStream(source.body);
    addTearDown(pump.close);

    pump.resume(prefix: '{"audio":"', suffix: '"}');
    var drainCompleted = false;
    final drain = pump.drainAndFlush().then((stats) {
      drainCompleted = true;
      return stats;
    });
    await receivedAll.future.timeout(const Duration(seconds: 10));
    expect(drainCompleted, isFalse);
    allowSourceEof.complete();
    final stats = await drain.timeout(const Duration(seconds: 10));

    expect(receivedBytes, sourceBytes);
    expect(stats.byteCount, sourceBytes.length);
    expect(stats.chunkCount, greaterThan(0));
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
