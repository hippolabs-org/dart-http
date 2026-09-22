import 'dart:io';

import 'package:dart_http_jaspr/dart_http_jaspr.dart';
import 'package:dart_http_server/dart_http_server.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart' show Component;
import 'package:jaspr/server.dart' as jaspr_server show Document;
import 'package:test/test.dart';

void main() {
  test('renders Jaspr components into HTML strings', () async {
    final html = await JasprRenderer.renderString(
      jaspr_server.Document(
        title: 'Welcome',
        base: null,
        body: div([Component.text('Hello from Jaspr')]),
      ),
    );

    expect(html, contains('<title>Welcome</title>'));
    expect(html, contains('Hello from Jaspr'));
  });

  test('mounts a Jaspr app as one catch-all Shelf-backed route', () async {
    final app = DartHttp<void>(services: () {});
    app.mountJasprApp(
      jaspr_server.Document(
        title: 'Mounted',
        base: null,
        body: div([Component.text('Mounted body')]),
      ),
      catchAllPath: '/<jasprPath*>',
      paths: const [],
    );

    expect(app.routeRegistry.registrations, hasLength(1));
    expect(app.routeRegistry.registrations.single.httpPath, '/<jasprPath*>');

    final server = await app.listen(port: 0);
    final client = HttpClient();

    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });

    final response = await (await client.getUrl(
      Uri.http('127.0.0.1:${server.port}', '/nested/page'),
    )).close();
    final html = await response.transform(SystemEncoding().decoder).join();

    expect(response.statusCode, HttpStatus.ok);
    expect(html, contains('Mounted body'));
  });

  test('can mount a Jaspr app without Jaspr static file handling', () async {
    final app = DartHttp<void>(services: () {});
    app.mountJasprApp(
      jaspr_server.Document(
        title: 'Mounted',
        base: null,
        body: div([Component.text('Mounted body')]),
      ),
      catchAllPath: '/docs/<jasprPath*>',
      paths: const [],
      serveStaticFiles: false,
      handlerPath: '/docs',
    );

    final server = await app.listen(port: 0);
    final client = HttpClient();

    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });

    final baseUri = Uri.http('127.0.0.1:${server.port}');
    final response = await (await client.getUrl(baseUri.resolve('/docs/nested/page'))).close();
    final html = await response.transform(SystemEncoding().decoder).join();

    expect(response.statusCode, HttpStatus.ok);
    expect(html, contains('Mounted body'));

    final staticResponse = await (await client.getUrl(baseUri.resolve('/docs/styles.css'))).close();
    await staticResponse.drain<void>();

    expect(staticResponse.statusCode, HttpStatus.notFound);
  });
}
