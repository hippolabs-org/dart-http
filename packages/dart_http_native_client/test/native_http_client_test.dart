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

  test('reports network body consumption before response, with an explicit measurement', () async {
    final firstProgress = Completer<void>();
    final releaseTail = Completer<void>();
    final releaseResponse = Completer<void>();
    final receivedAll = Completer<void>();
    final events = <DartHttpClientUploadProgress>[];
    server.listen((request) async {
      await request.drain<void>();
      receivedAll.complete();
      await releaseResponse.future;
      await request.response.close();
    });
    final response = transport.send(
      DartHttpClientRequest(
        method: HttpMethod.post,
        uri: Uri.parse('http://${server.address.host}:${server.port}/progress'),
        bodyStream: () async* {
          yield const [1, 2, 3];
          await releaseTail.future;
          yield const [4, 5, 6];
        }(),
        bodyStreamLength: 6,
        onUploadProgress: (event) {
          events.add(event);
          if (event.bytes == 3 && !firstProgress.isCompleted) firstProgress.complete();
        },
      ),
    );
    await firstProgress.future.timeout(const Duration(seconds: 5));
    expect(events.single.totalBytes, 6);
    expect(events.single.measurement, DartHttpClientUploadMeasurement.transportConsumed);
    releaseTail.complete();
    await receivedAll.future.timeout(const Duration(seconds: 5));
    releaseResponse.complete();
    await response;
    expect(events.last.bytes, 6);
    expect(
      events.map((e) => e.bytes),
      orderedEquals(events.map((e) => e.bytes).toSet().toList()..sort()),
    );
  });

  test('reports exact buffered UTF-8 body progress and preserves content length', () async {
    final events = <DartHttpClientUploadProgress>[];
    server.listen((request) async {
      expect(request.contentLength, utf8.encode('héllo').length);
      expect(await utf8.decoder.bind(request).join(), 'héllo');
      await request.response.close();
    });
    await transport.send(
      DartHttpClientRequest(
        method: HttpMethod.post,
        uri: Uri.parse('http://${server.address.host}:${server.port}/progress'),
        body: 'héllo',
        onUploadProgress: events.add,
      ),
    );
    expect(events.last.bytes, utf8.encode('héllo').length);
    expect(events.last.totalBytes, utf8.encode('héllo').length);
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

  test('applies a total request timeout only when explicitly configured', () async {
    transport.close();
    transport = await NativeHttpClientTransport.open(
      requestTimeout: const Duration(milliseconds: 50),
    );
    server.listen((request) async {
      request.response.bufferOutput = false;
      request.response.write('data: first\n\n');
      await request.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await request.response.close();
    });

    final response = await transport.sendStream(
      DartHttpClientRequest(
        method: HttpMethod.get,
        uri: Uri.parse('http://${server.address.host}:${server.port}/timed-events'),
      ),
    );

    await expectLater(response.bodyStream.drain<void>(), throwsA(isA<NativeHttpClientException>()));
  });

  test('returns redirects when following is disabled', () async {
    var redirectedRequestReceived = false;
    server.listen((request) async {
      if (request.uri.path == '/redirected') {
        redirectedRequestReceived = true;
        request.response.write('redirected');
      } else {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, '/redirected');
      }
      await request.response.close();
    });

    final response = await transport.send(
      DartHttpClientRequest(
        method: HttpMethod.get,
        uri: Uri.parse('http://${server.address.host}:${server.port}/redirect'),
        redirectPolicy: DartHttpClientRedirectPolicy.none,
      ),
    );

    expect(response.status, HttpStatus.found);
    expect(redirectedRequestReceived, isFalse);
  });

  test('follows redirects by default', () async {
    server.listen((request) async {
      if (request.uri.path == '/redirected') {
        request.response.write('redirected');
      } else {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, '/redirected');
      }
      await request.response.close();
    });

    final response = await transport.send(
      DartHttpClientRequest(
        method: HttpMethod.get,
        uri: Uri.parse('http://${server.address.host}:${server.port}/redirect'),
      ),
    );

    expect(response.status, HttpStatus.ok);
    expect(response.body, 'redirected');
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

  group('an early-ended streamed response body', () {
    late Completer<void> keepOpen;

    setUp(() {
      keepOpen = Completer<void>();
      addTearDown(() {
        if (!keepOpen.isCompleted) keepOpen.complete();
      });
      server.listen((request) async {
        request.response.bufferOutput = false;
        request.response.write('first-');
        await request.response.flush();
        await keepOpen.future;
        request.response.write('rest');
        await request.response.close();
      });
    });

    Uri slowUri() => Uri.parse('http://${server.address.host}:${server.port}/slow-body');

    test('errors when the abort trigger fires mid-body', () async {
      final abort = Completer<void>();
      final response = await transport.sendStream(
        DartHttpClientRequest(method: HttpMethod.get, uri: slowUri(), abortTrigger: abort.future),
      );
      final chunks = <List<int>>[];
      final done = response.bodyStream.forEach((chunk) {
        chunks.add(chunk);
        if (!abort.isCompleted) abort.complete();
      });

      await expectLater(
        done.timeout(const Duration(seconds: 5)),
        throwsA(isA<NativeHttpClientException>()),
      );
      expect(utf8.decode(chunks.expand((chunk) => chunk).toList()), 'first-');
    });

    test('errors when the transport closes mid-body', () async {
      final response = await transport.sendLeasedStream(
        DartHttpClientRequest(method: HttpMethod.get, uri: slowUri()),
      );
      final done = response.bodyStream.forEach((lease) {
        lease.close();
        transport.close();
      });

      await expectLater(
        done.timeout(const Duration(seconds: 5)),
        throwsA(isA<NativeHttpClientException>()),
      );
    });

    test('invokeStream surfaces a timeout instead of a truncated body', () async {
      final client = _StreamingClient(
        Uri.parse('http://${server.address.host}:${server.port}'),
        transport,
      );
      final response = await client.invokeStream(
        const DartHttpClientInvocation<Object?, Object?, Object?, Object?, Object?>(
          method: HttpMethod.get,
          pathTemplate: '/slow-body',
          timeout: Duration(milliseconds: 300),
          success: DartHttpClientResponseSpec<Object?>(
            status: 200,
            contentType: 'application/octet-stream',
          ),
        ),
      );

      await expectLater(
        response.requireBodyStream.drain<void>().timeout(const Duration(seconds: 5)),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('invokeStream does not abort a completed body after the timeout', () async {
      keepOpen.complete();
      final client = _StreamingClient(
        Uri.parse('http://${server.address.host}:${server.port}'),
        transport,
      );
      final response = await client.invokeStream(
        const DartHttpClientInvocation<Object?, Object?, Object?, Object?, Object?>(
          method: HttpMethod.get,
          pathTemplate: '/slow-body',
          timeout: Duration(milliseconds: 200),
          success: DartHttpClientResponseSpec<Object?>(
            status: 200,
            contentType: 'application/octet-stream',
          ),
        ),
      );
      final body = await utf8.decoder.bind(response.requireBodyStream).join();
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(body, 'first-rest');
    });
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

  test('extracts selected JSON audio into native leases and preserves control metadata', () async {
    server.listen((request) async {
      final peer = await WebSocketTransformer.upgrade(request);
      peer.listen(peer.add);
    });
    final socket = await transport.connect(
      DartHttpClientWebSocketRequest(
        uri: Uri.parse('ws://${server.address.host}:${server.port}/json-audio'),
      ),
    );
    addTearDown(socket.close);
    (socket as DartHttpClientJsonBinaryWebSocket).setJsonBase64Decoding(const [
      WebSocketJsonBase64Rule(
        pointer: '/parts/*/a~1b~0c',
        matchPointer: '/type',
        matchValues: ['audio'],
      ),
    ]);
    final incoming = StreamIterator(socket.messages);
    addTearDown(incoming.cancel);
    final first = incoming.moveNext();
    await socket.sendJson({
      'type': 'control',
      'parts': [
        {'a/b~c': 'unchanged'},
      ],
    });
    expect(await first, isTrue);
    expect(incoming.current.hasJsonBinaryLeases, isFalse);
    expect(jsonDecode(incoming.current.text)['parts'][0]['a/b~c'], 'unchanged');
    final second = incoming.moveNext();
    await socket.sendJson({
      'type': 'audio',
      'sequence': 7,
      'interrupted': true,
      'parts': [
        {'a/b~c': 'AQID'},
        {'a/b~c': 'BAUG'},
      ],
    });
    expect(await second, isTrue);
    final message = incoming.current;
    expect(message.hasJsonBinaryLeases, isTrue);
    final metadata = jsonDecode(message.text);
    expect(metadata['sequence'], 7);
    expect(metadata['interrupted'], isTrue);
    expect(metadata['parts'][0]['a/b~c'], isNull);
    final payloads = message.takeJsonBinaryLeases();
    expect(message.takeJsonBinaryLeases(), isEmpty);
    expect(payloads.keys, ['/parts/0/a~1b~0c', '/parts/1/a~1b~0c']);
    expect(payloads.values.first.bytesView, [1, 2, 3]);
    expect(payloads.values.last.bytesView, [4, 5, 6]);
    message.close(); // Transferred owners remain valid independently.
    expect(payloads.values.first.isClosed, isFalse);
    for (final payload in payloads.values) {
      payload.close();
    }
    final third = incoming.moveNext();
    await socket.sendJson({
      'type': 'audio',
      'parts': [
        {'a/b~c': 'AQID'},
      ],
    });
    expect(await third, isTrue);
    incoming.current.close();
    expect(incoming.current.hasJsonBinaryLeases, isFalse);
  });

  group('keepalive', () {
    // dart:io answers pings only while the server socket is being read.
    test('fails a connection whose peer stops answering pings', () async {
      server.listen((request) async {
        (await WebSocketTransformer.upgrade(request)).listen((_) {});
      });
      final proxy = await _SilencingProxy.start(server.port);
      addTearDown(proxy.close);
      final socket = await transport.connect(
        DartHttpClientWebSocketRequest(
          uri: Uri.parse('ws://127.0.0.1:${proxy.port}/keepalive'),
          keepAlive: const WebSocketKeepAlive(
            interval: Duration(milliseconds: 100),
            timeout: Duration(milliseconds: 150),
          ),
        ),
      );
      final failure = Completer<Object>();
      socket.messages.listen((_) {}, onError: failure.complete, onDone: () {});
      // Healthy pings are answered for a while before the peer goes silent.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(failure.isCompleted, isFalse);
      proxy.silence();

      final error = await failure.future.timeout(const Duration(seconds: 2));

      expect('$error', contains('keepalive timed out'));
      await proxy.clientDisconnected.timeout(const Duration(seconds: 2));
    });

    test('keeps a healthy idle connection open', () async {
      final serverSocket = Completer<WebSocket>();
      server.listen((request) async {
        final upgraded = await WebSocketTransformer.upgrade(request);
        upgraded.listen((_) {});
        serverSocket.complete(upgraded);
      });
      final socket = await transport.connect(
        DartHttpClientWebSocketRequest(
          uri: Uri.parse('ws://${server.address.host}:${server.port}/keepalive'),
          // Generous timeout: a loaded test machine may answer pings late.
          keepAlive: const WebSocketKeepAlive(
            interval: Duration(milliseconds: 100),
            timeout: Duration(milliseconds: 500),
          ),
        ),
      );
      final errors = <Object>[];
      final messages = <String>[];
      socket.messages.listen((message) => messages.add(message.text), onError: errors.add);

      await Future<void>.delayed(const Duration(milliseconds: 1000));
      (await serverSocket.future).add('still here');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(errors, isEmpty);
      expect(messages, ['still here']);
      await socket.close();
    });

    test('rejects a non-positive interval', () {
      expect(
        () => transport.connect(
          DartHttpClientWebSocketRequest(
            uri: Uri.parse('ws://127.0.0.1:1/'),
            keepAlive: const WebSocketKeepAlive(interval: Duration.zero),
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  group('a peer that never answers close', () {
    late _SilencingProxy proxy;
    late NativeHttpClientTransport closingTransport;

    setUp(() async {
      server.listen((request) async {
        await WebSocketTransformer.upgrade(request);
      });
      proxy = await _SilencingProxy.start(server.port);
      closingTransport = await NativeHttpClientTransport.open(
        webSocketCloseTimeout: const Duration(milliseconds: 300),
      );
    });

    tearDown(() async {
      closingTransport.close();
      await proxy.close();
    });

    Future<NativeHttpWebSocket> connect() async => await closingTransport.connect(
      DartHttpClientWebSocketRequest(uri: Uri.parse('ws://127.0.0.1:${proxy.port}/silent')),
    ) as NativeHttpWebSocket;

    test('is torn down after the close deadline', () async {
      final socket = await connect();
      final ended = socket.messages.drain<void>();
      proxy.silence();
      final watch = Stopwatch()..start();

      await socket.close();
      await ended.timeout(const Duration(seconds: 2));
      await proxy.clientDisconnected.timeout(const Duration(seconds: 2));

      expect(watch.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 250)));
      expect(socket.closeDetails, isNull);
    });

    test('ends quietly when the transport closes during the handshake', () async {
      final socket = await connect();
      final errors = <Object>[];
      final ended = Completer<void>();
      socket.messages.listen((_) {}, onError: errors.add, onDone: ended.complete);
      proxy.silence();

      await socket.close();
      closingTransport.close();
      await ended.future.timeout(const Duration(seconds: 2));

      expect(errors, isEmpty);
    });
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

  test('keeps sending while the native receive queue is backpressured', () async {
    transport.close();
    transport = await NativeHttpClientTransport.open(
      webSocketIncomingCapacity: 1,
      webSocketOutgoingCapacity: 1,
    );
    final receivedByServer = Completer<String>();
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((message) {
        if (!receivedByServer.isCompleted) receivedByServer.complete(message as String);
      });
      socket
        ..add('first')
        ..add('second');
    });
    final socket = await transport.connect(
      DartHttpClientWebSocketRequest(
        uri: Uri.parse('ws://${server.address.host}:${server.port}/independent-writer'),
      ),
    );
    addTearDown(socket.close);

    // Leave the message stream unobserved so the one-slot native receive queue
    // fills and backpressures the socket reader.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await socket.sendText('outgoing').timeout(const Duration(seconds: 2));

    expect(await receivedByServer.future.timeout(const Duration(seconds: 2)), 'outgoing');
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

  test('drains a native byte stream before one trailing binary frame', () async {
    final allowSourceEof = Completer<void>();
    final received = <List<int>>[];
    final receivedBoundary = Completer<void>();
    server.listen((request) async {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((message) {
          received.add((message as List<int>).toList(growable: false));
          if (received.last case [9, 9, 9]) receivedBoundary.complete();
        });
        return;
      }
      request.response.add(const <int>[1, 2, 3, 4]);
      await request.response.flush();
      await allowSourceEof.future;
      await request.response.close();
    });
    final socket = await transport.connect(
      DartHttpClientWebSocketRequest(
        uri: Uri.parse('ws://${server.address.host}:${server.port}/drain-boundary'),
      ),
    );
    addTearDown(socket.close);
    final source = await transport.sendNative(
      DartHttpClientRequest(
        method: HttpMethod.get,
        uri: Uri.parse('http://${server.address.host}:${server.port}/source'),
      ),
    );
    final pump = (socket as DartHttpClientNativeStreamWebSocket).adoptByteStream(source.body);
    addTearDown(pump.close);

    pump.resume();
    final drain = pump.drainAndSendBinary(const <int>[9, 9, 9]);
    allowSourceEof.complete();
    final stats = await drain.timeout(const Duration(seconds: 5));
    await receivedBoundary.future.timeout(const Duration(seconds: 5));

    expect(received, <List<int>>[
      <int>[1, 2, 3, 4],
      <int>[9, 9, 9],
    ]);
    expect(stats.chunkCount, 1);
    expect(stats.byteCount, 4);
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

  test('canceling a blocked native pump leaves control commands usable', () async {
    final firstAudio = Completer<void>();
    final releaseSource = Completer<void>();
    addTearDown(() {
      if (!releaseSource.isCompleted) releaseSource.complete();
    });
    server.listen((request) async {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final peer = await WebSocketTransformer.upgrade(request);
        peer.listen((frame) {
          if (frame == 'after-cancel') {
            peer.add('confirmed');
          } else if (!firstAudio.isCompleted) {
            firstAudio.complete();
          }
        });
      } else {
        request.response.add(List<int>.filled(16 * 1024, 1));
        await request.response.flush();
        await releaseSource.future;
        await request.response.close();
      }
    });
    final socket = await transport.connect(
      DartHttpClientWebSocketRequest(
        uri: Uri.parse('ws://${server.address.host}:${server.port}/cancel-pump'),
      ),
    );
    addTearDown(socket.close);
    final received = Completer<void>();
    final errors = <Object>[];
    final subscription = socket.messages.listen((message) {
      try {
        if (message.text == 'confirmed') received.complete();
      } finally {
        message.close();
      }
    }, onError: errors.add);
    addTearDown(subscription.cancel);
    final source = await transport.sendNative(
      DartHttpClientRequest(
        method: HttpMethod.get,
        uri: Uri.parse('http://${server.address.host}:${server.port}/blocked'),
      ),
    );
    final pump = (socket as DartHttpClientNativeStreamWebSocket).adoptBase64TextStream(source.body);
    pump.resume(prefix: '{"audio":"', suffix: '"}');
    await firstAudio.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    pump.close();
    await socket.sendText('after-cancel');
    await received.future.timeout(const Duration(seconds: 5));
    expect(errors, isEmpty);
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

  test('keeps repeated response headers instead of the last value', () async {
    final raw = await _RawHttpServer.start((socket) async {
      socket.write(
        'HTTP/1.1 200 OK\r\n'
        'vary: accept\r\n'
        'vary: origin\r\n'
        'set-cookie: a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT\r\n'
        'set-cookie: b=2\r\n'
        'content-length: 2\r\n'
        'connection: close\r\n'
        '\r\n'
        'ok',
      );
      await socket.flush();
      await socket.close();
    });
    addTearDown(raw.close);

    final response = await transport.send(
      DartHttpClientRequest(method: HttpMethod.get, uri: raw.uri('/headers')),
    );

    expect(response.headers['vary'], 'accept, origin');
    expect(response.headers['set-cookie']!.split('\n'), [
      'a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT',
      'b=2',
    ]);
  });

  test('returns an early server error sent before the streamed body is read', () async {
    final raw = await _RawHttpServer.start((socket) async {
      socket.write(
        'HTTP/1.1 413 Payload Too Large\r\n'
        'content-length: 0\r\n'
        'connection: close\r\n'
        '\r\n',
      );
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      socket.destroy();
    });
    addTearDown(raw.close);
    const chunkSize = 1024 * 1024;
    const chunkCount = 256;

    final response = await transport
        .send(
          DartHttpClientRequest(
            method: HttpMethod.post,
            uri: raw.uri('/too-large'),
            bodyStream: () async* {
              for (var index = 0; index < chunkCount; index++) {
                yield List<int>.filled(chunkSize, index & 0xff);
                await Future<void>.delayed(Duration.zero);
              }
            }(),
            bodyStreamLength: chunkSize * chunkCount,
          ),
        )
        .timeout(const Duration(seconds: 20));

    expect(response.status, 413);
  });

  test('lets an unlistened streamed response body be finalized', () async {
    server.listen((request) async {
      request.response.write('x' * 1024);
      await request.response.close();
    });
    final uri = Uri.parse('http://${server.address.host}:${server.port}/unlistened');

    Future<void> sendAndDrop() async {
      final response = await transport.sendStream(
        DartHttpClientRequest(method: HttpMethod.get, uri: uri),
      );
      expect(response.status, 200);
    }

    await sendAndDrop();
    expect(transport.debugOpenResponseReaderCount, 1);
    expect(transport.debugStronglyHeldResponseReaderCount, 0);

    final deadline = DateTime.now().add(const Duration(seconds: 20));
    var garbage = <List<int>>[];
    while (transport.debugOpenResponseReaderCount != 0 && DateTime.now().isBefore(deadline)) {
      // Allocate until the VM collects the dropped response and runs its
      // finalizer.
      for (var index = 0; index < 64; index++) {
        garbage.add(List<int>.filled(16 * 1024, index));
      }
      if (garbage.length > 4096) garbage = <List<int>>[];
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(transport.debugOpenResponseReaderCount, 0);
  });

  test('holds a streamed body strongly only while it is read', () async {
    server.listen((request) async {
      request.response.write('hello');
      await request.response.close();
    });
    final uri = Uri.parse('http://${server.address.host}:${server.port}/listened');

    final unlistened = await transport.sendStream(
      DartHttpClientRequest(method: HttpMethod.get, uri: uri),
    );
    final listened = await transport.sendStream(
      DartHttpClientRequest(method: HttpMethod.get, uri: uri),
    );
    expect(transport.debugOpenResponseReaderCount, 2);
    expect(utf8.decode(await listened.bodyStream.expand((chunk) => chunk).toList()), 'hello');
    expect(transport.debugOpenResponseReaderCount, 1);
    expect(transport.debugStronglyHeldResponseReaderCount, 0);

    transport.close();
    expect(transport.debugOpenResponseReaderCount, 0);
    expect(unlistened.status, 200);
  });

  test('learns of a peer close on a socket that is only sent on', () async {
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add('before close');
      socket.listen((_) {});
      await socket.close(4001, 'bye');
    });
    final socket = await transport.connect(
      DartHttpClientWebSocketRequest(
        uri: Uri.parse('ws://${server.address.host}:${server.port}/send-only'),
      ),
    ) as NativeHttpWebSocket;

    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (socket.closeDetails == null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(socket.closeDetails?.code, 4001);
    expect(socket.closeDetails?.reason, 'bye');
    await expectLater(socket.sendText('after close'), throwsA(isA<NativeHttpClientException>()));

    // Frames received before the close still reach a late listener.
    final messages = await socket.messages.toList().timeout(const Duration(seconds: 5));
    expect(messages.map((message) => message.text), ['before close']);
  });

  test('a close rejected by a full send queue leaves the socket usable', () async {
    transport.close();
    transport = await NativeHttpClientTransport.open(webSocketOutgoingCapacity: 1);
    final received = <String>[];
    final peerClosed = Completer<int?>();
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen(
        (message) => received.add(message as String),
        onDone: () => peerClosed.complete(socket.closeCode),
      );
    });
    final socket = await transport.connect(
      DartHttpClientWebSocketRequest(
        uri: Uri.parse('ws://${server.address.host}:${server.port}/close-full-queue'),
      ),
    );
    final ended = socket.messages.drain<void>();

    final first = socket.sendText('first');
    await expectLater(
      socket.close(),
      throwsA(
        isA<NativeHttpClientException>().having(
          (error) => error.message,
          'message',
          contains('queue is full'),
        ),
      ),
    );
    await first;
    await socket.sendText('second');
    await socket.close(1000, 'done');
    await ended.timeout(const Duration(seconds: 5));

    expect(await peerClosed.future.timeout(const Duration(seconds: 5)), 1000);
    expect(received, ['first', 'second']);
  });
}

/// Minimal HTTP/1.1 server that answers each connection with hand-written
/// bytes once the request head arrived.
final class _RawHttpServer {
  _RawHttpServer._(this._server, Future<void> Function(Socket socket) respond) {
    _server.listen((socket) {
      final head = <int>[];
      var answered = false;
      socket.listen((data) {
        if (answered) return;
        head.addAll(data);
        if (latin1.decode(head, allowInvalid: true).contains('\r\n\r\n')) {
          answered = true;
          unawaited(respond(socket).catchError((Object _) {}));
        }
      }, onError: (Object _) {});
    });
  }

  static Future<_RawHttpServer> start(Future<void> Function(Socket socket) respond) async =>
      _RawHttpServer._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), respond);

  final ServerSocket _server;

  Uri uri(String path) => Uri.parse('http://127.0.0.1:${_server.port}$path');

  Future<void> close() => _server.close();
}

/// Forwards TCP traffic to a WebSocket server until [silence] is called, then
/// drops everything the server sends, so the client's close goes unanswered.
final class _SilencingProxy {
  _SilencingProxy._(this._server, this._upstreamPort) {
    _server.listen((client) async {
      final upstream = await Socket.connect(InternetAddress.loopbackIPv4, _upstreamPort);
      _sockets.addAll([client, upstream]);
      upstream.listen((data) {
        if (!_silenced) client.add(data);
      }, onError: (Object _) {});
      client.listen(
        upstream.add,
        onError: (Object _) {},
        onDone: () {
          if (!_disconnected.isCompleted) _disconnected.complete();
          upstream.destroy();
        },
      );
    });
  }

  static Future<_SilencingProxy> start(int upstreamPort) async =>
      _SilencingProxy._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), upstreamPort);

  final ServerSocket _server;
  final int _upstreamPort;
  final _sockets = <Socket>[];
  final _disconnected = Completer<void>();
  var _silenced = false;

  int get port => _server.port;

  /// Completes when the client side of the connection closes.
  Future<void> get clientDisconnected => _disconnected.future;

  void silence() => _silenced = true;

  Future<void> close() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
    await _server.close();
  }
}

final class _StreamingClient extends DartHttpClientBase {
  _StreamingClient(Uri baseUri, NativeHttpClientTransport transport)
    : super(baseUri: baseUri, transport: transport);
}
