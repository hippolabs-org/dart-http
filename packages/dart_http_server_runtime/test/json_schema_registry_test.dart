import 'dart:convert';

import 'package:dart_http_server_runtime/dart_http_server_runtime.dart';
import 'package:dart_http_server_runtime/src/runtime/compiled_route_table.dart';
import 'package:json_schema/json_schema.dart';
import 'package:test/test.dart';

void main() {
  test('stores installed schema registries on the app', () {
    const registry = JsonSchemaRegistry(
      schemas: <JsonSchema>[
        JsonSchema.object(id: 'UsersInsert', description: 'Insert payload for users.'),
      ],
    );

    final app = DartHttp<void>(services: () {});
    app.installSchemaRegistry(registry);

    expect(app.schemaRegistry, same(registry));
    expect(app.schemaRegistry?.schemaFor('UsersInsert')?.description, 'Insert payload for users.');
    expect(app.schemaRegistry?.schemaFor('UsersInsert')?.toJson(), {
      r'$id': 'UsersInsert',
      'type': 'object',
      'description': 'Insert payload for users.',
    });
  });

  test('uses immutable OpenAPI document metadata from the constructor', () {
    final servers = [const OpenApiServer(url: 'https://api.example.test')];
    final app = DartHttp<void>(
      services: () {},
      openApiDocument: OpenApiDocument(
        title: 'Example API',
        version: '2026.04.26',
        description: 'Immutable API metadata.',
        servers: servers,
      ),
    );
    servers.add(const OpenApiServer(url: 'https://mutated.example.test'));

    final document = app.buildOpenApiDocumentJson();
    expect(document['info'], {
      'title': 'Example API',
      'version': '2026.04.26',
      'description': 'Immutable API metadata.',
    });
    expect(document['servers'], [
      {'url': 'https://api.example.test'},
    ]);
    expect(
      () =>
          app.openApiDocument.servers.add(const OpenApiServer(url: 'https://blocked.example.test')),
      throwsUnsupportedError,
    );
  });

  test('includes rich OpenAPI metadata, tags, docs, and server variables', () {
    final serverVariableValues = <String>['v1', 'v2'];
    final serverVariables = <String, OpenApiServerVariable>{
      'version': OpenApiServerVariable(
        defaultValue: 'v1',
        description: 'API version.',
        enumValues: serverVariableValues,
      ),
    };
    final tags = <OpenApiTag>[
      const OpenApiTag(
        name: 'users',
        description: 'User operations.',
        externalDocs: OpenApiExternalDocumentation(url: 'https://docs.example.test/users'),
      ),
    ];
    final app = DartHttp<void>(
      services: () {},
      openApiDocument: OpenApiDocument(
        title: 'Example API',
        version: '2.0.0',
        summary: 'Example service.',
        description: 'Longer API description.',
        termsOfService: 'https://example.test/terms',
        contact: const OpenApiContact(
          name: 'API Support',
          url: 'https://example.test/support',
          email: 'support@example.test',
        ),
        license: const OpenApiLicense(name: 'MIT', identifier: 'MIT'),
        servers: <OpenApiServer>[
          OpenApiServer(
            url: 'https://api.example.test/{version}',
            description: 'Production API.',
            variables: serverVariables,
          ),
        ],
        tags: tags,
        externalDocs: const OpenApiExternalDocumentation(
          url: 'https://docs.example.test',
          description: 'API guide.',
        ),
      ),
    );

    serverVariableValues.add('v3');
    serverVariables.clear();
    tags.clear();

    final document = app.buildOpenApiDocumentJson();
    expect(document['info'], {
      'title': 'Example API',
      'version': '2.0.0',
      'summary': 'Example service.',
      'description': 'Longer API description.',
      'termsOfService': 'https://example.test/terms',
      'contact': {
        'name': 'API Support',
        'url': 'https://example.test/support',
        'email': 'support@example.test',
      },
      'license': {'name': 'MIT', 'identifier': 'MIT'},
    });
    expect(document['servers'], [
      {
        'url': 'https://api.example.test/{version}',
        'description': 'Production API.',
        'variables': {
          'version': {
            'default': 'v1',
            'description': 'API version.',
            'enum': ['v1', 'v2'],
          },
        },
      },
    ]);
    expect(document['tags'], [
      {
        'name': 'users',
        'description': 'User operations.',
        'externalDocs': {'url': 'https://docs.example.test/users'},
      },
    ]);
    expect(document['externalDocs'], {
      'url': 'https://docs.example.test',
      'description': 'API guide.',
    });
  });

  test('includes global OpenAPI security schemes and requirements', () {
    final schemes = <String, OpenApiSecurityScheme>{
      'BearerAuth': const OpenApiSecurityScheme.http(scheme: 'bearer'),
      'ApiKeyAuth': const OpenApiSecurityScheme.apiKey(
        name: 'X-API-Key',
        in_: OpenApiApiKeyLocation.header,
      ),
    };
    final requirements = <OpenApiSecurityRequirement>[
      OpenApiSecurityRequirement.scheme('BearerAuth'),
    ];
    final app = DartHttp<void>(
      services: () {},
      openApiDocument: OpenApiDocument(securitySchemes: schemes, security: requirements),
    );

    schemes['BasicAuth'] = const OpenApiSecurityScheme.http(scheme: 'basic');
    requirements.add(OpenApiSecurityRequirement.scheme('BasicAuth'));

    final document = app.buildOpenApiDocumentJson();
    expect(document['components'], {
      'securitySchemes': {
        'BearerAuth': {'type': 'http', 'scheme': 'bearer'},
        'ApiKeyAuth': {'type': 'apiKey', 'name': 'X-API-Key', 'in': 'header'},
      },
    });
    expect(document['security'], [
      {'BearerAuth': <String>[]},
    ]);
    expect(
      () => app.openApiDocument.securitySchemes['BasicAuth'] = const OpenApiSecurityScheme.http(
        scheme: 'basic',
      ),
      throwsUnsupportedError,
    );
    expect(
      () => app.openApiDocument.security.add(OpenApiSecurityRequirement.scheme('BasicAuth')),
      throwsUnsupportedError,
    );
  });

  test('merges OpenAPI schemas and security schemes into components', () {
    const registry = JsonSchemaRegistry(schemas: <JsonSchema>[JsonSchema.object(id: 'User')]);
    final app = DartHttp<void>(
      services: () {},
      openApiDocument: OpenApiDocument(
        securitySchemes: const <String, OpenApiSecurityScheme>{
          'BearerAuth': OpenApiSecurityScheme.http(scheme: 'bearer'),
        },
      ),
    )..installSchemaRegistry(registry);

    expect(app.buildOpenApiDocumentJson()['components'], {
      'schemas': {
        'User': {'type': 'object'},
      },
      'securitySchemes': {
        'BearerAuth': {'type': 'http', 'scheme': 'bearer'},
      },
    });
  });

  test('documents binary responses for default and custom content types', () {
    final app = DartHttp<void>(services: () {});
    app.get(
      '/download',
      options: const RouteOptions(success: ResponseSpec.binary()),
      handler: (_) => const <int>[],
    );
    app.get(
      '/audio',
      options: const RouteOptions(success: ResponseSpec.binary(contentType: 'audio/wav')),
      handler: (_) => const <int>[],
    );

    final paths = app.buildOpenApiDocumentJson()['paths']! as Map<String, Object?>;

    expect(paths['/download'], {
      'get': {
        'operationId': 'getDownload',
        'responses': {
          '200': {
            'description': 'OK',
            'content': {
              'application/octet-stream': {
                'schema': {'type': 'string', 'format': 'binary'},
              },
            },
          },
        },
      },
    });
    expect(paths['/audio'], {
      'get': {
        'operationId': 'getAudio',
        'responses': {
          '200': {
            'description': 'OK',
            'content': {
              'audio/wav': {
                'schema': {'type': 'string', 'format': 'binary'},
              },
            },
          },
        },
      },
    });
  });

  test('includes installed schemas in the native manifest', () {
    const registry = JsonSchemaRegistry(
      schemas: <JsonSchema>[
        JsonSchema.object(
          id: 'UsersInsert',
          properties: <String, JsonSchema>{'email': JsonSchema.string()},
        ),
      ],
    );

    final app = DartHttp<void>(services: () {});
    app.routePost('/users', _SchemaRoute());

    final compiledRoutes = CompiledRouteTable.fromRegistrations(app.routeRegistry.registrations);
    final manifest = jsonDecode(
      compiledRoutes.nativeManifestJson(schemaRegistry: registry),
    ) as Map<String, Object?>;

    expect(
      manifest['schemas'],
      containsPair('UsersInsert', {
        r'$id': 'UsersInsert',
        'type': 'object',
        'properties': {
          'email': {'type': 'string'},
        },
      }),
    );
  });

  test('includes component refs without duplicating the schema graph', () {
    const registry = JsonSchemaRegistry(
      schemas: <JsonSchema>[
        JsonSchema.array(id: 'ListSort', items: JsonSchema.componentRef('ListSortItem')),
        JsonSchema.object(
          id: 'ListSortItem',
          properties: <String, JsonSchema>{'field': JsonSchema.string()},
          required: <String>['field'],
          additionalProperties: false,
        ),
      ],
    );

    final app = DartHttp<void>(services: () {});
    app.routePost('/users', _SchemaRoute());

    final compiledRoutes = CompiledRouteTable.fromRegistrations(app.routeRegistry.registrations);
    final manifest = jsonDecode(
      compiledRoutes.nativeManifestJson(schemaRegistry: registry),
    ) as Map<String, Object?>;
    final schemas = manifest['schemas']! as Map<String, Object?>;

    expect(schemas['ListSort'], {
      r'$id': 'ListSort',
      'type': 'array',
      'items': {r'$ref': '#/components/schemas/ListSortItem'},
    });
    expect(schemas['ListSortItem'], {
      r'$id': 'ListSortItem',
      'type': 'object',
      'properties': {
        'field': {'type': 'string'},
      },
      'required': ['field'],
      'additionalProperties': false,
    });
  });

  test('does not treat inline route schema ids as native manifest refs', () {
    final app = DartHttp<void>(services: () {});
    app.get(
      '/users/<id>',
      options: RouteOptions(
        params: const JsonSchema.object(
          id: 'UserPath',
          properties: <String, JsonSchema>{'id': JsonSchema.string()},
        ),
        query: const JsonSchema.object(
          id: 'UserQuery',
          properties: <String, JsonSchema>{'search': JsonSchema.string()},
        ),
      ),
      handler: (_) => const {'ok': true},
    );

    final compiledRoutes = CompiledRouteTable.fromRegistrations(app.routeRegistry.registrations);
    final manifest = jsonDecode(compiledRoutes.nativeManifestJson()) as Map<String, Object?>;
    final routes = manifest['routes']! as List<Object?>;
    final route = routes.single as Map<String, Object?>;

    expect(route['paramsSchemaId'], isNull);
    expect(route['querySchemaId'], isNull);
  });

  test('includes explicit route schema refs in the native manifest', () {
    final app = DartHttp<void>(services: () {});
    app.get(
      '/users/<id>',
      options: const RouteOptions(
        params: JsonSchema.ref('UserPath'),
        query: JsonSchema.ref('UserQuery'),
      ),
      handler: (_) => const {'ok': true},
    );

    final compiledRoutes = CompiledRouteTable.fromRegistrations(app.routeRegistry.registrations);
    final manifest = jsonDecode(compiledRoutes.nativeManifestJson()) as Map<String, Object?>;
    final routes = manifest['routes']! as List<Object?>;
    final route = routes.single as Map<String, Object?>;

    expect(route['paramsSchemaId'], 'UserPath');
    expect(route['querySchemaId'], 'UserQuery');
  });

  test('includes websocket params schema refs in the native manifest', () {
    final app = DartHttp<void>(services: () {});
    app.websocket(
      '/calls/<id>/live',
      options: const WebSocketOptions(
        operationId: 'connectLiveCall',
        maxPendingMessages: 12,
        maxPendingBytes: 3456,
        params: JsonSchema.ref('IdParams'),
        query: JsonSchema.ref('LiveCallQuery'),
        queryDecoder: _decodeLiveCallQuery,
      ),
      onConnect: (_) async {},
    );

    final compiledRoutes = CompiledRouteTable.fromRegistrations(app.routeRegistry.registrations);
    final manifest = jsonDecode(compiledRoutes.nativeManifestJson()) as Map<String, Object?>;
    final routes = manifest['routes']! as List<Object?>;
    final route = routes.single as Map<String, Object?>;
    final compiledRoute = compiledRoutes.webSocketRoutes.single;

    expect(route['kind'], 'webSocket');
    expect(route['paramsSchemaId'], 'IdParams');
    expect(route['querySchemaId'], 'LiveCallQuery');
    expect(route['maxPendingMessages'], 12);
    expect(route['maxPendingBytes'], 3456);
    expect(compiledRoute.options.queryDecoder, same(_decodeLiveCallQuery));
  });
}

Object? _decodeLiveCallQuery(Map<String, String> values) => values;

final class _SchemaRoute extends HttpRouteDefinition<void, Map<String, Object?>> {
  @override
  RouteOptions get options => RouteOptions(
    operationId: 'createUser',
    body: RequestBody.json(schema: const JsonSchema.ref('UsersInsert')),
    success: ResponseSpec.json(),
  );

  @override
  Map<String, Object?> handle(RequestContext<void> ctx) => const {'ok': true};
}
