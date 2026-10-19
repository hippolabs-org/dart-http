import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_http_server_runtime/dart_http_server_runtime.dart';
import 'package:test/test.dart';

void main() {
  group('repeated request values', () {
    late DartHttpServer server;

    setUp(() async {
      final app = DartHttp<void>(services: () {});
      app.get(
        '/echo',
        handler: (ctx) => {
          'cookie': ctx.req.header('cookie'),
          'forwardedFor': ctx.req.header('x-forwarded-for'),
          'name': ctx.req.header('x-name'),
          'a': ctx.req.queryParam('a'),
          'aAll': ctx.req.queryParamValues('a'),
          'bAll': ctx.req.queryParamValues('b'),
          'missing': ctx.req.queryParamValues('missing'),
        },
      );
      server = await app.listen(port: 0);
    });

    tearDown(() => server.close());

    test('joins repeated headers and keeps every repeated query value', () async {
      final response = await _rawRequest(
        server.port,
        'GET /echo?a=1&b=x&a=2 HTTP/1.1\r\n'
        'Host: localhost\r\n'
        'Cookie: session=abc\r\n'
        'Cookie: theme=dark\r\n'
        'X-Forwarded-For: 10.0.0.1\r\n'
        'X-Forwarded-For: 10.0.0.2\r\n'
        'Connection: close\r\n\r\n',
      );

      expect(response.status, HttpStatus.ok);
      final body = jsonDecode(response.body) as Map<String, Object?>;
      expect(body['cookie'], 'session=abc; theme=dark');
      expect(body['forwardedFor'], '10.0.0.1, 10.0.0.2');
      expect(body['a'], '2');
      expect(body['aAll'], ['1', '2']);
      expect(body['bAll'], ['x']);
      expect(body['missing'], isEmpty);
    });

    test('keeps non-ASCII header values instead of dropping them', () async {
      final socket = await Socket.connect('127.0.0.1', server.port);
      socket.add(
        utf8.encode(
          'GET /echo HTTP/1.1\r\nHost: localhost\r\nX-Name: Jürgen\r\nConnection: close\r\n\r\n',
        ),
      );
      final response = _RawResponse.parse(await _readAll(socket));

      expect(response.status, HttpStatus.ok);
      expect((jsonDecode(response.body) as Map<String, Object?>)['name'], 'Jürgen');
    });
  });

  group('method routing', () {
    late DartHttpServer server;

    setUp(() async {
      final app = DartHttp<void>(services: () {});
      app.get('/thing', handler: (_) => RawResponse.text(status: 200, body: 'hello'));
      app.put('/thing', handler: (_) => RawResponse.text(status: 200, body: 'put'));
      app.post('/only-post', handler: (_) => RawResponse.text(status: 200, body: 'posted'));
      server = await app.listen(port: 0);
    });

    tearDown(() => server.close());

    test('answers HEAD from the GET route without a body', () async {
      final response = await _rawRequest(
        server.port,
        'HEAD /thing HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n',
      );

      expect(response.status, HttpStatus.ok);
      expect(response.headers['content-length'], '5');
      expect(response.body, isEmpty);
    });

    test('answers a known path with the wrong method with 405 and Allow', () async {
      final response = await _rawRequest(
        server.port,
        'DELETE /thing HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n',
      );

      expect(response.status, HttpStatus.methodNotAllowed);
      expect(_csv(response.headers['allow']), unorderedEquals(['GET', 'HEAD', 'PUT']));
    });

    test('does not offer HEAD for a path without a GET route', () async {
      final response = await _rawRequest(
        server.port,
        'HEAD /only-post HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n',
      );

      expect(response.status, HttpStatus.methodNotAllowed);
      expect(_csv(response.headers['allow']), ['POST']);
    });

    test('still answers unknown paths with 404', () async {
      final response = await _rawRequest(
        server.port,
        'GET /missing HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n',
      );

      expect(response.status, HttpStatus.notFound);
    });
  });
}

List<String> _csv(String? value) =>
    value?.split(',').map((part) => part.trim()).where((part) => part.isNotEmpty).toList() ??
    const <String>[];

Future<_RawResponse> _rawRequest(int port, String request) async {
  final socket = await Socket.connect('127.0.0.1', port);
  socket.write(request);
  return _RawResponse.parse(await _readAll(socket));
}

Future<List<int>> _readAll(Socket socket) async {
  final bytes = <int>[];
  final done = Completer<void>();
  final subscription = socket.listen(
    bytes.addAll,
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
    onError: (Object _) {
      if (!done.isCompleted) done.complete();
    },
  );
  // A rejected upgrade may keep the connection open; stop once the response
  // has stopped arriving.
  await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
  await subscription.cancel();
  socket.destroy();
  return bytes;
}

final class _RawResponse {
  _RawResponse(this.status, this.headers, this.body);

  factory _RawResponse.parse(List<int> bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    final split = text.indexOf('\r\n\r\n');
    final head = split < 0 ? text : text.substring(0, split);
    final body = split < 0 ? '' : text.substring(split + 4);
    final lines = head.split('\r\n');
    final status = int.parse(lines.first.split(' ')[1]);
    final headers = <String, String>{};
    for (final line in lines.skip(1)) {
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      headers[line.substring(0, colon).trim().toLowerCase()] = line.substring(colon + 1).trim();
    }
    return _RawResponse(status, headers, body);
  }

  final int status;
  final Map<String, String> headers;
  final String body;
}
