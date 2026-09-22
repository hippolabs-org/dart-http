import 'dart:io';

import 'package:dart_http_server/dart_http_server.dart';
import 'package:dart_http_shelf/dart_http_shelf.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

void main() {
  test('mounts a Shelf handler as a streaming catch-all route', () async {
    final app = DartHttp<void>(services: () {});

    app.mountShelfHandler(
      (request) => shelf.Response.ok(
        Stream<List<int>>.fromIterable(['method=${request.method};url=${request.url}'.codeUnits]),
        headers: {'content-type': 'text/plain; charset=utf-8', 'x-shelf-handler': 'true'},
      ),
      methods: const [HttpMethod.get],
    );

    final server = await app.listen(port: 0);
    final client = HttpClient();

    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });

    final baseUri = Uri.http('127.0.0.1:${server.port}');
    final rootResponse = await (await client.getUrl(baseUri.resolve('/'))).close();
    final rootBody = await rootResponse.transform(SystemEncoding().decoder).join();

    expect(rootResponse.statusCode, HttpStatus.ok);
    expect(rootResponse.headers.value('x-shelf-handler'), 'true');
    expect(rootBody, 'method=GET;url=');

    final nestedResponse = await (await client.getUrl(baseUri.resolve('/assets/styles.css?v=1')))
        .close();
    final nestedBody = await nestedResponse.transform(SystemEncoding().decoder).join();

    expect(nestedResponse.statusCode, HttpStatus.ok);
    expect(nestedBody, 'method=GET;url=assets/styles.css?v=1');
  });

  test('forwards request bodies and headers to Shelf handlers', () async {
    final app = DartHttp<void>(services: () {});

    app.mountShelfHandler((request) async {
      final body = await request.readAsString();
      return shelf.Response(
        HttpStatus.created,
        body: '$body:${request.headers['x-test']}',
        headers: {'content-type': 'text/plain; charset=utf-8'},
      );
    }, methods: const [HttpMethod.post]);

    final server = await app.listen(port: 0);
    final client = HttpClient();

    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });

    final request = await client.postUrl(Uri.http('127.0.0.1:${server.port}', '/echo'));
    request.headers.set('x-test', 'forwarded');
    request.write('hello shelf');
    final response = await request.close();
    final body = await response.transform(SystemEncoding().decoder).join();

    expect(response.statusCode, HttpStatus.created);
    expect(body, 'hello shelf:forwarded');
  });

  test('includes a router prefix in the forwarded request path', () async {
    final app = DartHttp<void>(services: () {});
    final assets = app.router('/assets');
    assets.mountShelfHandler(
      (request) => shelf.Response.ok(request.requestedUri.path),
      methods: const [HttpMethod.get],
    );

    final server = await app.listen(port: 0);
    final client = HttpClient();

    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });

    final response = await (await client.getUrl(
      Uri.http('127.0.0.1:${server.port}', '/assets/icons/logo.svg'),
    )).close();
    final body = await response.transform(SystemEncoding().decoder).join();

    expect(response.statusCode, HttpStatus.ok);
    expect(body, '/assets/icons/logo.svg');
  });
}
