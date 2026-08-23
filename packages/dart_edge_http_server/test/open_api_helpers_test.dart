import 'dart:convert';
import 'dart:io';

import 'package:dart_edge_http_server/dart_edge_http_server.dart';
import 'package:json_schema/json_schema.dart';
import 'package:test/test.dart';

void main() {
  test('serves the generated OpenAPI document and Swagger UI', () async {
    final app = DartEdge<void>(
      services: () {},
      openApiDocument: OpenApiDocument(title: 'Example API', version: '2026.04.17'),
    );
    app.get('/health', handler: (_) => const {'status': 'ok'});
    OpenApiHelpers.mountJson(app, path: '/openapi.json');
    OpenApiHelpers.mountSwaggerUi(app, path: '/docs', specPath: '/openapi.json');

    final server = await app.listen(port: 0);
    final client = HttpClient();

    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });

    final baseUri = Uri.http('127.0.0.1:${server.port}');

    final openApiResponse = await (await client.getUrl(baseUri.resolve('/openapi.json'))).close();
    expect(openApiResponse.statusCode, HttpStatus.ok);
    expect(openApiResponse.headers.contentType?.mimeType, 'application/json');

    final openApiJson =
        jsonDecode(await utf8.decoder.bind(openApiResponse).join()) as Map<String, Object?>;
    expect(openApiJson['openapi'], '3.1.0');
    expect(openApiJson['info'], containsPair('title', 'Example API'));
    expect(openApiJson['paths'], contains('/health'));
    expect(openApiJson['paths'], isNot(contains('/openapi.json')));
    expect(openApiJson['paths'], isNot(contains('/docs')));

    final docsResponse = await (await client.getUrl(baseUri.resolve('/docs'))).close();
    expect(docsResponse.statusCode, HttpStatus.ok);
    expect(docsResponse.headers.contentType?.mimeType, 'text/html');

    final html = await utf8.decoder.bind(docsResponse).join();
    expect(html, contains('SwaggerUIBundle'));
    expect(html, contains('/openapi.json'));
  });

  test('serves formatted OpenAPI JSON for direct inspection', () async {
    final app = DartEdge<void>(services: () {});
    app.get('/health', handler: (_) => const {'status': 'ok'});
    OpenApiHelpers.mountJson(app, path: '/openapi.json');

    final server = await app.listen(port: 0);
    final client = HttpClient();

    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });

    final baseUri = Uri.http('127.0.0.1:${server.port}');
    final response = await (await client.getUrl(baseUri.resolve('/openapi.json'))).close();
    final body = await utf8.decoder.bind(response).join();

    expect(body, startsWith('{\n  "openapi": "3.1.0"'));
    expect(body, contains('\n  "paths": {'));
  });

  test('builds OpenAPI paths from compiled routes and inherited router tags', () {
    final app = DartEdge<void>(services: () {});
    final api = app.router('/api', tags: const ['api']);
    final users = api.router('/users', tags: const ['users']);

    users.get(
      '/:id',
      options: RouteOptions(summary: 'Load one user.'),
      handler: (_) => const {'ok': true},
    );

    final document = app.buildOpenApiDocumentJson();
    final paths = document['paths']! as Map<String, Object?>;
    final userPath = paths['/api/users/{id}']! as Map<String, Object?>;
    final operation = userPath['get']! as Map<String, Object?>;

    expect(operation['summary'], 'Load one user.');
    expect(operation['tags'], ['api', 'users']);
    expect(operation['parameters'], contains(containsPair('name', 'id')));
  });

  test('excludes routes from OpenAPI by route and router exposure', () {
    final app = DartEdge<void>(services: () {});
    app.get('/public', handler: (_) => const {'ok': true});
    app.get(
      '/hidden',
      options: const RouteOptions(exposure: RouteExposure.clientOnly),
      handler: (_) => const {'ok': true},
    );
    app
        .router('/internal', exposure: RouteExposure.none)
        .get('/health', handler: (_) => const {'ok': true});

    final mounted = Router<void>(exposure: RouteExposure.clientOnly);
    mounted.get('/status', handler: (_) => const {'ok': true});
    app.mountRouter('/mounted', mounted, exposure: RouteExposure.openApiOnly);

    OpenApiHelpers.mountJson(app, path: '/openapi.json');
    OpenApiHelpers.mountSwaggerUi(app, path: '/docs', specPath: '/openapi.json');

    final document = app.buildOpenApiDocumentJson();
    final paths = document['paths']! as Map<String, Object?>;

    expect(paths, contains('/public'));
    expect(paths, isNot(contains('/hidden')));
    expect(paths, isNot(contains('/internal/health')));
    expect(paths, isNot(contains('/mounted/status')));
    expect(paths, isNot(contains('/openapi.json')));
    expect(paths, isNot(contains('/docs')));
  });

  test('emits inline route schemas without registered components', () {
    final app = DartEdge<void>(services: () {});
    app.post(
      '/users/:id',
      options: RouteOptions(
        summary: 'Update one user.',
        params: const JsonSchema.object(
          properties: <String, JsonSchema>{
            'id': JsonSchema.string(description: 'User identifier.'),
          },
          required: <String>['id'],
        ),
        query: const JsonSchema.object(
          properties: <String, JsonSchema>{
            'notify': JsonSchema.boolean(description: 'Whether to send a notification.'),
          },
        ),
        body: RequestBody.json(
          schema: const JsonSchema.object(
            properties: <String, JsonSchema>{'name': JsonSchema.string()},
            required: <String>['name'],
          ),
        ),
        success: ResponseSpec.json(
          schema: const JsonSchema.object(
            properties: <String, JsonSchema>{'id': JsonSchema.string()},
            required: <String>['id'],
          ),
        ),
      ),
      handler: (_) => const {'id': 'user-1'},
    );

    final document = app.buildOpenApiDocumentJson();
    expect(document, isNot(contains('components')));

    final paths = document['paths']! as Map<String, Object?>;
    final userPath = paths['/users/{id}']! as Map<String, Object?>;
    final operation = userPath['post']! as Map<String, Object?>;
    final parameters = operation['parameters']! as List<Object?>;

    expect(
      parameters,
      contains(
        allOf(
          containsPair('name', 'id'),
          containsPair('in', 'path'),
          containsPair('description', 'User identifier.'),
        ),
      ),
    );
    expect(
      parameters,
      contains(
        allOf(
          containsPair('name', 'notify'),
          containsPair('in', 'query'),
          containsPair('description', 'Whether to send a notification.'),
        ),
      ),
    );

    final requestBody = operation['requestBody']! as Map<String, Object?>;
    final requestContent = requestBody['content']! as Map<String, Object?>;
    final requestJson = requestContent['application/json']! as Map<String, Object?>;
    expect(requestJson['schema'], containsPair('required', ['name']));

    final responses = operation['responses']! as Map<String, Object?>;
    final ok = responses['200']! as Map<String, Object?>;
    final responseContent = ok['content']! as Map<String, Object?>;
    final responseJson = responseContent['application/json']! as Map<String, Object?>;
    expect(responseJson['schema'], containsPair('required', ['id']));
  });

  test('resolves OpenAPI object schemas only through explicit refs', () {
    const registry = JsonSchemaRegistry(
      schemas: <JsonSchema>[
        JsonSchema.object(
          id: 'UserPath',
          properties: <String, JsonSchema>{
            'id': JsonSchema.string(description: 'Resolved from registry.'),
          },
        ),
      ],
    );

    final inlineApp = DartEdge<void>(services: () {});
    inlineApp.installSchemaRegistry(registry);
    inlineApp.get(
      '/users/:id',
      options: const RouteOptions(params: JsonSchema.object(id: 'UserPath')),
      handler: (_) => const {'ok': true},
    );

    final inlineDocument = inlineApp.buildOpenApiDocumentJson();
    final inlineParameter = _firstPathParameter(inlineDocument, '/users/{id}');
    expect(inlineParameter, isNot(containsPair('description', anything)));
    expect(inlineParameter['schema'], {'type': 'string'});

    final referencedApp = DartEdge<void>(services: () {});
    referencedApp.installSchemaRegistry(registry);
    referencedApp.get(
      '/users/:id',
      options: const RouteOptions(params: JsonSchema.ref('UserPath')),
      handler: (_) => const {'ok': true},
    );

    final referencedDocument = referencedApp.buildOpenApiDocumentJson();
    final referencedParameter = _firstPathParameter(referencedDocument, '/users/{id}');
    expect(referencedParameter['description'], 'Resolved from registry.');
  });
}

Map<String, Object?> _firstPathParameter(Map<String, Object?> document, String path) {
  final paths = document['paths']! as Map<String, Object?>;
  final pathItem = paths[path]! as Map<String, Object?>;
  final operation = pathItem['get']! as Map<String, Object?>;
  final parameters = operation['parameters']! as List<Object?>;
  return parameters.single as Map<String, Object?>;
}
