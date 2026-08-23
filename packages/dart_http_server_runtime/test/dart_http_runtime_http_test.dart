import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_http_server_runtime/dart_http_server_runtime.dart';
import 'package:dart_http_server_runtime/src/native/http_native_bridge.dart'
    show NativeBinaryPayloadLease;
import 'package:test/test.dart';

void main() {
  test('serves requests without a services factory when TServices is void', () async {
    final app = DartHttp<void>();
    app.get('/hello', handler: (_) => 'Hello, World!');

    final server = await app.listen(port: 0);
    final client = HttpClient();

    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });

    final response = await (await client.getUrl(Uri.http('127.0.0.1:${server.port}', '/hello')))
        .close();
    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.contentType?.mimeType, 'application/json');
    expect(await utf8.decoder.bind(response).join(), '"Hello, World!"');
  });

  test('decodes percent-encoded query parameters', () async {
    final app = DartHttp<void>(services: () {});
    app.get(
      '/oauth/start',
      handler: (ctx) => {
        'callbackURL': ctx.req.queryParam('callbackURL'),
        'name': ctx.req.queryParam('name'),
      },
    );

    final server = await app.listen(port: 0);
    final client = HttpClient();

    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });

    final response = await (await client.getUrl(
      Uri.parse(
        'http://127.0.0.1:${server.port}/oauth/start?'
        'callbackURL=http%3A%2F%2F127.0.0.1%3A51663%2Fcallback&'
        'name=Ada+Lovelace',
      ),
    )).close();

    expect(response.statusCode, HttpStatus.ok);
    final body = jsonDecode(await utf8.decoder.bind(response).join()) as Map<String, Object?>;
    expect(body, {'callbackURL': 'http://127.0.0.1:51663/callback', 'name': 'Ada Lovelace'});
  });

  test('runs request observers around Dart HTTP routes', () async {
    final observations = <HttpRequestObservation>[];
    final results = <HttpRequestObservationResult>[];
    final app = DartHttp<void>(
      services: () {},
      requestObservers: [_RecordingObserver(observations, results)],
    );
    app.get(
      '/users/<id>',
      options: const RouteOptions(
        operationId: 'getUser',
        success: ResponseSpec.json(status: HttpStatus.accepted),
      ),
      handler: (ctx) => {'id': ctx.req.param('id')},
    );

    final server = await app.listen(port: 0);
    final client = HttpClient();

    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });

    final response = await (await client.getUrl(Uri.http('127.0.0.1:${server.port}', '/users/42')))
        .close();
    await response.drain<void>();

    expect(response.statusCode, HttpStatus.accepted);
    expect(observations, hasLength(1));
    expect(observations.single.method, HttpMethod.get);
    expect(observations.single.route, '/users/<id>');
    expect(observations.single.operationId, 'getUser');
    expect(results.single.statusCode, HttpStatus.accepted);
    expect(results.single.responseBodySize, isPositive);
  });

  test('starts with webtransport routes in the native manifest', () async {
    final app = DartHttp<void>(services: () {});
    app.webtransport(
      '/events',
      options: const WebTransportOptions(operationId: 'connectEvents'),
      onConnect: (transport) async {
        await for (final datagram in transport.datagrams.datagrams()) {
          await transport.sendDatagram(datagram);
        }
      },
    );

    final server = await app.listen(port: 0);

    addTearDown(server.close);
    expect(server.port, isPositive);
  });

  test('binds to an explicit deploy host and serves requests', () async {
    final app = DartHttp<void>(services: () {});
    app.get('/health', handler: (_) => const {'status': 'ok'});

    final server = await app.listen(host: '0.0.0.0', port: 0);
    final client = HttpClient();

    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });

    expect(server.host, '0.0.0.0');

    final response = await (await client.getUrl(Uri.http('127.0.0.1:${server.port}', '/health')))
        .close();
    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.contentType?.mimeType, 'application/json');

    final body = jsonDecode(await utf8.decoder.bind(response).join()) as Map<String, Object?>;
    expect(body, containsPair('status', 'ok'));
  });

  test('runs two native HTTP servers on independent ports', () async {
    final firstApp = DartHttp<void>(services: () {});
    final secondApp = DartHttp<void>(services: () {});
    firstApp.get('/first', handler: (_) => const {'server': 'first'});
    secondApp.get('/second', handler: (_) => const {'server': 'second'});

    final firstServer = await firstApp.listen(host: '127.0.0.1', port: 0);
    final secondServer = await secondApp.listen(host: '127.0.0.1', port: 0);
    final client = HttpClient();

    addTearDown(() async {
      client.close(force: true);
      await secondServer.close();
      await firstServer.close();
    });

    expect(firstServer.port, isPositive);
    expect(secondServer.port, isPositive);
    expect(secondServer.port, isNot(firstServer.port));

    final firstResponse = await (await client.getUrl(
      Uri.http('127.0.0.1:${firstServer.port}', '/first'),
    )).close();
    final secondResponse = await (await client.getUrl(
      Uri.http('127.0.0.1:${secondServer.port}', '/second'),
    )).close();
    final crossResponse = await (await client.getUrl(
      Uri.http('127.0.0.1:${firstServer.port}', '/second'),
    )).close();

    expect(firstResponse.statusCode, HttpStatus.ok);
    expect(secondResponse.statusCode, HttpStatus.ok);
    expect(crossResponse.statusCode, HttpStatus.notFound);

    expect(jsonDecode(await utf8.decoder.bind(firstResponse).join()), {'server': 'first'});
    expect(jsonDecode(await utf8.decoder.bind(secondResponse).join()), {'server': 'second'});
    await crossResponse.drain<void>();
  });

  test('serves raw binary responses without UTF-8 string encoding', () async {
    final app = DartHttp<void>(services: () {});
    final bytes = Uint8List.fromList([0, 255, 1, 2, 128, 3]);
    app.get(
      '/tone.wav',
      options: const RouteOptions(
        operationId: 'getTone',
        success: ResponseSpec.binary(contentType: 'audio/wav'),
      ),
      handler: (_) =>
          RawResponse.binary(status: HttpStatus.ok, contentType: 'audio/wav', body: bytes),
    );

    final server = await app.listen(port: 0);
    final client = HttpClient();

    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });

    final response = await (await client.getUrl(Uri.http('127.0.0.1:${server.port}', '/tone.wav')))
        .close();
    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.contentType?.mimeType, 'audio/wav');
    final body = await response.fold<List<int>>(<int>[], (buffer, chunk) => buffer..addAll(chunk));
    expect(body, bytes);
  });

  test('streams binary responses in order with a content length', () async {
    final app = DartHttp<void>(services: () {});
    var disposeCount = 0;
    final chunks = <List<int>>[
      [0, 255],
      [1, 2, 128],
      [3],
    ];
    app.get(
      '/stream.wav',
      options: const RouteOptions(
        operationId: 'streamTone',
        success: ResponseSpec.binary(contentType: 'audio/wav'),
      ),
      handler: (_) => BinaryStreamResponse(
        body: Stream<List<int>>.fromIterable(chunks),
        contentType: 'audio/wav',
        contentLength: chunks.fold<int>(0, (length, chunk) => length + chunk.length),
        headers: const [HttpHeader('Content-Disposition', 'attachment; filename="tone.wav"')],
        onDispose: () {
          disposeCount += 1;
        },
      ),
    );

    final server = await app.listen(port: 0);
    final client = HttpClient();

    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });

    final response = await (await client.getUrl(
      Uri.http('127.0.0.1:${server.port}', '/stream.wav'),
    )).close();
    expect(response.statusCode, HttpStatus.ok);
    expect(response.contentLength, 6);
    expect(response.headers.value('content-disposition'), 'attachment; filename="tone.wav"');
    expect(await response.fold<List<int>>(<int>[], (buffer, chunk) => buffer..addAll(chunk)), [
      0,
      255,
      1,
      2,
      128,
      3,
    ]);
    expect(disposeCount, 1);
  });

  test('serves single byte ranges with 206 and 416 metadata', () async {
    final bytes = List<int>.generate(10, (index) => index);
    final app = DartHttp<void>(services: () {});
    app.get(
      '/range.wav',
      options: const RouteOptions(
        operationId: 'rangeTone',
        success: ResponseSpec.binary(contentType: 'audio/wav'),
      ),
      handler: (ctx) {
        final range = HttpByteRange.parse(ctx.req.header('range')!);
        final selection = range.resolve(bytes.length);
        if (selection == null) {
          return RawResponse.rangeNotSatisfiable(totalLength: bytes.length);
        }
        return BinaryStreamResponse.partial(
          body: Stream.value(bytes.sublist(selection.start, selection.end + 1)),
          contentType: 'audio/wav',
          range: selection,
        );
      },
    );

    final server = await app.listen(port: 0);
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });

    final partialRequest = await client.getUrl(Uri.http('127.0.0.1:${server.port}', '/range.wav'));
    partialRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=2-4');
    final partial = await partialRequest.close();
    expect(partial.statusCode, HttpStatus.partialContent);
    expect(partial.contentLength, 3);
    expect(partial.headers.value('accept-ranges'), 'bytes');
    expect(partial.headers.value('content-range'), 'bytes 2-4/10');
    expect(await partial.expand((chunk) => chunk).toList(), [2, 3, 4]);

    final invalidRequest = await client.getUrl(Uri.http('127.0.0.1:${server.port}', '/range.wav'));
    invalidRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=10-');
    final invalid = await invalidRequest.close();
    expect(invalid.statusCode, HttpStatus.requestedRangeNotSatisfiable);
    expect(invalid.headers.value('content-range'), 'bytes */10');
    await invalid.drain<void>();
  });

  test('handles CORS preflight and adds CORS headers to responses', () async {
    final app = DartHttp<void>(
      services: () {},
      middlewares: [
        RustMiddleware.cors(
          allowOrigins: const ['http://localhost:5173'],
          allowHeaders: const ['content-type', 'authorization'],
        ),
      ],
    );
    app.post('/users', handler: (_) => const {'status': 'created'});

    final server = await app.listen(port: 0);
    final client = HttpClient();

    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });

    final preflightRequest = await client.openUrl(
      'OPTIONS',
      Uri.http('127.0.0.1:${server.port}', '/users'),
    );
    preflightRequest.headers
      ..set('origin', 'http://localhost:5173')
      ..set(HttpHeaders.accessControlRequestMethodHeader, 'POST')
      ..set(HttpHeaders.accessControlRequestHeadersHeader, 'content-type, authorization');
    final preflightResponse = await preflightRequest.close();

    expect(preflightResponse.statusCode, HttpStatus.ok);
    expect(
      preflightResponse.headers.value(HttpHeaders.accessControlAllowOriginHeader),
      'http://localhost:5173',
    );
    expect(
      preflightResponse.headers.value(HttpHeaders.accessControlAllowMethodsHeader),
      contains('POST'),
    );
    expect(
      preflightResponse.headers.value(HttpHeaders.accessControlAllowMethodsHeader),
      contains('OPTIONS'),
    );
    expect(
      _csvHeaderValues(
        preflightResponse.headers.value(HttpHeaders.accessControlAllowHeadersHeader),
      ),
      containsAll(['content-type', 'authorization']),
    );

    final postRequest = await client.postUrl(Uri.http('127.0.0.1:${server.port}', '/users'));
    postRequest.headers
      ..set('origin', 'http://localhost:5173')
      ..contentType = ContentType.json;
    postRequest.write('{}');
    final postResponse = await postRequest.close();

    expect(postResponse.statusCode, HttpStatus.ok);
    expect(
      postResponse.headers.value(HttpHeaders.accessControlAllowOriginHeader),
      'http://localhost:5173',
    );
  });

  test('supports ctx.req and ctx.res overrides with a returned body', () async {
    final app = DartHttp<void>(services: () {});
    app.get(
      '/users/<id>',
      handler: (ctx) {
        final params = ctx.req.params<Map<String, String>>();
        ctx.res.status(HttpStatus.accepted).header('x-user-id', params['id'] ?? '');
        return {'id': params['id']};
      },
    );

    final server = await app.listen(port: 0);
    final client = HttpClient();

    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });

    final response = await (await client.getUrl(Uri.http('127.0.0.1:${server.port}', '/users/42')))
        .close();
    expect(response.statusCode, HttpStatus.accepted);
    expect(response.headers.value('x-user-id'), '42');
    expect(response.headers.contentType?.mimeType, 'application/json');

    final body = jsonDecode(await utf8.decoder.bind(response).join()) as Map<String, Object?>;
    expect(body, {'id': '42'});
  });

  test('supports ctx.res.send without returning a response', () async {
    final app = DartHttp<void>(services: () {});
    app.get(
      '/reply',
      handler: (ctx) {
        ctx.res.status(HttpStatus.created).send('created');
      },
    );

    final server = await app.listen(port: 0);
    final client = HttpClient();

    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });

    final response = await (await client.getUrl(Uri.http('127.0.0.1:${server.port}', '/reply')))
        .close();
    expect(response.statusCode, HttpStatus.created);
    expect(response.headers.contentType?.mimeType, 'text/plain');
    expect(await utf8.decoder.bind(response).join(), 'created');
  });

  test('supports ctx.res.type(...).send(jsonEncode(...)) directly', () async {
    final app = DartHttp<void>(services: () {});
    app.get(
      '/reply-json',
      handler: (ctx) {
        return ctx.res
            .code(HttpStatus.accepted)
            .type('application/json; charset=utf-8')
            .send(jsonEncode({'status': 'ok'}));
      },
    );

    final server = await app.listen(port: 0);
    final client = HttpClient();

    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });

    final response = await (await client.getUrl(
      Uri.http('127.0.0.1:${server.port}', '/reply-json'),
    )).close();
    expect(response.statusCode, HttpStatus.accepted);
    expect(response.headers.contentType?.mimeType, 'application/json');
    expect(await utf8.decoder.bind(response).join(), '{"status":"ok"}');
  });

  test('exposes a native request with a borrowed body for pass-through handlers', () async {
    final app = DartHttp<void>(services: () {});
    app.post(
      '/native-body',
      handler: (ctx) {
        final body = ctx.req.nativeBody;
        return {
          'hasNativeBody': body != null,
          'length': body?.length ?? 0,
          'text': body == null ? '' : utf8.decode(body.copyBytes()),
        };
      },
    );

    final server = await app.listen(port: 0);
    final client = HttpClient();

    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });

    final request = await client.postUrl(Uri.http('127.0.0.1:${server.port}', '/native-body'));
    request.headers.contentType = ContentType.text;
    request.write('hello native body');
    final response = await request.close();

    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.contentType?.mimeType, 'application/json');

    final body = jsonDecode(await utf8.decoder.bind(response).join()) as Map<String, Object?>;
    expect(body, {'hasNativeBody': true, 'length': 17, 'text': 'hello native body'});
  });

  test('parses multipart form-data with borrowed native file bodies', () async {
    final app = DartHttp<void>(services: () {});
    app.post(
      '/multipart',
      options: RouteOptions(body: RequestBody.multipartFormData()),
      handler: (ctx) async {
        final form = await ctx.req.multipart();
        final file = form.files.single;

        return {
          'title': form.fieldValue('title'),
          'fileFieldName': file.fieldName,
          'fileName': file.filename,
          'fileType': file.contentType,
          'fileLength': file.length,
          'fileText': utf8.decode(file.copyBytes()),
        };
      },
    );

    final server = await app.listen(port: 0);
    final client = HttpClient();

    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });

    const boundary = 'dart-http-boundary';
    final request = await client.postUrl(Uri.http('127.0.0.1:${server.port}', '/multipart'));
    request.headers.set(HttpHeaders.contentTypeHeader, 'multipart/form-data; boundary=$boundary');
    request.add(
      utf8.encode(
        '--$boundary\r\n'
        'Content-Disposition: form-data; name="title"\r\n'
        '\r\n'
        'hello multipart\r\n'
        '--$boundary\r\n'
        'Content-Disposition: form-data; name="upload"; filename="hello.txt"\r\n'
        'Content-Type: text/plain\r\n'
        '\r\n'
        'file payload\r\n'
        '--$boundary--\r\n',
      ),
    );
    final response = await request.close();

    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.contentType?.mimeType, 'application/json');

    final body = jsonDecode(await utf8.decoder.bind(response).join()) as Map<String, Object?>;
    expect(body, {
      'title': 'hello multipart',
      'fileFieldName': 'upload',
      'fileName': 'hello.txt',
      'fileType': 'text/plain',
      'fileLength': 12,
      'fileText': 'file payload',
    });
  });

  test('streams server-sent events responses', () async {
    final app = DartHttp<void>(services: () {});
    app.get(
      '/events',
      options: RouteOptions(success: ResponseSpec.sse()),
      handler: (ctx) {
        return ctx.res.sse(
          Stream<SseEvent>.fromIterable(const [
            SseEvent(event: 'ready', data: 'alpha'),
            SseEvent(id: 'evt-2', data: 'beta'),
          ]),
        );
      },
    );

    final server = await app.listen(port: 0);
    final client = HttpClient();

    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });

    final response = await (await client.getUrl(Uri.http('127.0.0.1:${server.port}', '/events')))
        .close();
    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.contentType?.mimeType, 'text/event-stream');
    expect(response.headers.value(HttpHeaders.cacheControlHeader), 'no-cache');
    expect(response.headers.value('x-accel-buffering'), 'no');
    expect(
      await utf8.decoder.bind(response).join(),
      'event: ready\n'
      'data: alpha\n'
      '\n'
      'id: evt-2\n'
      'data: beta\n'
      '\n',
    );
  });

  test('upgrades websocket routes and exchanges JSON messages', () async {
    final app = DartHttp<void>(services: () {});
    app.websocket(
      '/chat/<roomId>',
      onConnect: (socket) async {
        await socket.sendJson({
          'roomId': socket.req.param('roomId'),
          'token': socket.req.queryParam('token'),
        });

        await for (final message in socket.messages.json<Map<String, Object?>>()) {
          await socket.sendJson({'roomId': socket.req.param('roomId'), 'echo': message['message']});
        }
      },
    );

    final server = await app.listen(port: 0);
    final socket = await WebSocket.connect('ws://127.0.0.1:${server.port}/chat/alpha?token=secret');
    final messages = StreamIterator<dynamic>(socket);

    addTearDown(() async {
      await messages.cancel();
      await socket.close();
      await server.close();
    });

    expect(await messages.moveNext(), isTrue);
    expect(jsonDecode(messages.current as String), {'roomId': 'alpha', 'token': 'secret'});

    socket.add(jsonEncode({'message': 'hello'}));

    expect(await messages.moveNext(), isTrue);
    expect(jsonDecode(messages.current as String), {'roomId': 'alpha', 'echo': 'hello'});
  });

  test('websocket routes can exchange text and binary frames', () async {
    final app = DartHttp<void>(services: () {});
    app.websocket(
      '/audio',
      onConnect: (socket) async {
        await socket.sendText('ready');

        await for (final frame in socket.messages.frames()) {
          switch (frame.kind) {
            case WebSocketMessageKind.text:
              await socket.sendText('text:${frame.text}');
            case WebSocketMessageKind.binary:
              await socket.sendBinary([frame.bytes.length, ...frame.bytes.reversed]);
              await socket.close();
          }
        }
      },
    );

    final server = await app.listen(port: 0);
    final socket = await WebSocket.connect('ws://127.0.0.1:${server.port}/audio');
    final messages = StreamIterator<dynamic>(socket);

    addTearDown(() async {
      await messages.cancel();
      await socket.close();
      await server.close();
    });

    expect(await messages.moveNext(), isTrue);
    expect(messages.current, 'ready');

    socket.add('hello');

    expect(await messages.moveNext(), isTrue);
    expect(messages.current, 'text:hello');

    socket.add(Uint8List.fromList([1, 2, 3, 4]));

    expect(await messages.moveNext(), isTrue);
    expect(messages.current, [4, 4, 3, 2, 1]);
  });

  test('websocket routes can receive and send leased native frames', () async {
    final receivedNativeLease = Completer<bool>();
    final app = DartHttp<void>(services: () {});
    app.websocket(
      '/native-audio',
      onConnect: (socket) async {
        await for (final lease in socket.messages.leasedBinary()) {
          receivedNativeLease.complete(lease is NativeBinaryPayloadLease);
          await socket.sendBinaryLease(lease);
          await socket.close();
        }
      },
    );

    final server = await app.listen(port: 0);
    final socket = await WebSocket.connect('ws://127.0.0.1:${server.port}/native-audio');
    final messages = StreamIterator<dynamic>(socket);

    addTearDown(() async {
      await messages.cancel();
      await socket.close();
      await server.close();
    });

    socket.add(Uint8List.fromList([9, 8, 7, 6]));

    expect(await messages.moveNext(), isTrue);
    expect(messages.current, [9, 8, 7, 6]);
    expect(await receivedNativeLease.future, isTrue);
  });

  test('websocket guards can reject the upgrade handshake', () async {
    final app = DartHttp<void>(services: () {});
    app.websocket(
      '/guarded-socket',
      guards: [
        HandlerGuard<void>(
          debugName: 'denySocket',
          handler: (_) async {
            await Future<void>.delayed(const Duration(milliseconds: 1));
            return GuardResult.deny(
              RawResponse.text(status: HttpStatus.forbidden, body: 'socket blocked'),
            );
          },
        ),
      ],
      onConnect: (_) async {},
    );

    final server = await app.listen(port: 0);

    addTearDown(() async {
      await server.close();
    });

    await expectLater(
      () => WebSocket.connect('ws://127.0.0.1:${server.port}/guarded-socket'),
      throwsA(isA<WebSocketException>()),
    );
  });

  test('fails to start when the configured host is invalid', () async {
    final app = DartHttp<void>(services: () {});

    await expectLater(
      () => app.listen(host: '256.256.256.256', port: 0),
      throwsA(isA<StateError>()),
    );
  });

  test('runs route guards before the handler and can short-circuit', () async {
    final app = DartHttp<void>(services: () {});
    final protected = app.router(
      '',
      guards: [
        HandlerGuard<void>(
          debugName: 'denyAll',
          handler: (_) =>
              GuardResult.deny(RawResponse.text(status: HttpStatus.unauthorized, body: 'blocked')),
        ),
      ],
    );
    protected.get('/guarded', handler: (_) => 'ok');

    final server = await app.listen(port: 0);
    final client = HttpClient();

    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });

    final response = await (await client.getUrl(Uri.http('127.0.0.1:${server.port}', '/guarded')))
        .close();
    expect(response.statusCode, HttpStatus.unauthorized);
    expect(await utf8.decoder.bind(response).join(), 'blocked');
  });

  test('awaits async route guards before the handler', () async {
    final app = DartHttp<void>(services: () {});
    app.get(
      '/async-guarded',
      guards: [
        HandlerGuard<void>(
          debugName: 'asyncAllow',
          handler: (ctx) async {
            await Future<void>.delayed(const Duration(milliseconds: 1));
            ctx.put<String>('guarded');
            return const GuardResult.allow();
          },
        ),
      ],
      handler: (ctx) => ctx.require<String>(),
    );

    final server = await app.listen(port: 0);
    final client = HttpClient();

    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });

    final response = await (await client.getUrl(
      Uri.http('127.0.0.1:${server.port}', '/async-guarded'),
    )).close();
    expect(response.statusCode, HttpStatus.ok);
    expect(await utf8.decoder.bind(response).join(), '"guarded"');
  });

  test('runs inline helper and explicit contract guards', () async {
    final app = DartHttp<void>(services: () {});

    app.get(
      '/inline-guarded',
      guards: [
        HandlerGuard<void>(
          debugName: 'denyInline',
          handler: (_) =>
              GuardResult.deny(RawResponse.text(status: HttpStatus.forbidden, body: 'inline')),
        ),
      ],
      handler: (_) => 'ok',
    );
    app.routeGet(
      '/contract-guarded',
      _GuardedContractRoute(),
      guards: [
        HandlerGuard<void>(
          debugName: 'denyContract',
          handler: (_) =>
              GuardResult.deny(RawResponse.text(status: HttpStatus.forbidden, body: 'contract')),
        ),
      ],
    );

    final server = await app.listen(port: 0);
    final client = HttpClient();

    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });

    final inlineResponse = await (await client.getUrl(
      Uri.http('127.0.0.1:${server.port}', '/inline-guarded'),
    )).close();
    expect(inlineResponse.statusCode, HttpStatus.forbidden);
    expect(await utf8.decoder.bind(inlineResponse).join(), 'inline');

    final contractResponse = await (await client.getUrl(
      Uri.http('127.0.0.1:${server.port}', '/contract-guarded'),
    )).close();
    expect(contractResponse.statusCode, HttpStatus.forbidden);
    expect(await utf8.decoder.bind(contractResponse).join(), 'contract');
  });
}

List<String> _csvHeaderValues(String? value) {
  return value
          ?.split(',')
          .map((part) => part.trim().toLowerCase())
          .where((part) => part.isNotEmpty)
          .toList(growable: false) ??
      const <String>[];
}

final class _RecordingObserver implements HttpRequestObserver<void> {
  const _RecordingObserver(this.observations, this.results);

  final List<HttpRequestObservation> observations;
  final List<HttpRequestObservationResult> results;

  @override
  Future<HttpRequestObservationResult> observe({
    required RequestContext<void> context,
    required HttpRequestObservation request,
    required Future<HttpRequestObservationResult> Function() next,
  }) async {
    observations.add(request);
    final result = await next();
    results.add(result);
    return result;
  }
}

final class _GuardedContractRoute extends HttpRouteDefinition<void, String> {
  @override
  RouteOptions get options =>
      RouteOptions(operationId: 'contractGuarded', success: ResponseSpec.text());

  @override
  String handle(RequestContext<void> ctx) => 'ok';
}
