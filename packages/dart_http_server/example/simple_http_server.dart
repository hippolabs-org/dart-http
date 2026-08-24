import 'dart:async';

import 'package:dart_http_observability/dart_http_observability.dart';
import 'package:dart_http_server/dart_http_server.dart';
import 'package:json_schema/json_schema.dart';

Future<void> main() async {
  final observability = DartHttpObservability(config: ObservabilityConfig.fromEnvironment());
  final app = DartHttp<AppServices>(
    services: AppServices.new,
    openApiDocument: OpenApiDocument(title: 'Dart HTTP Example API', version: '0.1.0'),
    requestObservers: [observability.httpObserver<AppServices>()],
    middlewares: [
      RustMiddleware.compression(),
      RustMiddleware.bodyLimit(maxBytes: 1024 * 1024),
    ],
  );
  app.installSchemaRegistry(_schemaRegistry);
  app.installCodecRegistry(_codecRegistry);

  final api = app.router('/api');

  api.get(
    '/health',
    options: RouteOptions(
      operationId: 'healthCheck',
      summary: 'Return a basic health response.',
      success: ResponseSpec.json(schema: const JsonSchema.ref('HealthResponse')),
    ),
    handler: (ctx) {
      ctx.telemetry.addEvent('health.checked');
      return const HealthResponse(status: 'ok');
    },
  );
  api.get(
    '/users',
    options: RouteOptions(
      operationId: 'listUsers',
      summary: 'List users with an optional search filter.',
      query: const JsonSchema.ref('ListUsersQuery'),
      success: ResponseSpec.json(schema: const JsonSchema.ref('ListUsersResponse')),
    ),
    handler: (ctx) async {
      final query = ctx.req.query<ListUsersQuery>();
      final users = await ctx.services.users.list(search: query.search);
      return ListUsersResponse(items: users);
    },
  );
  api.post(
    '/users',
    options: RouteOptions(
      operationId: 'createUser',
      summary: 'Create a new user.',
      body: RequestBody.json(schema: const JsonSchema.ref('CreateUserInput')),
      success: ResponseSpec.json(status: 201, schema: const JsonSchema.ref('UserDto')),
      errors: [ErrorResponse.conflict(code: 'duplicate_email')],
    ),
    handler: (ctx) async {
      final input = ctx.req.body<CreateUserInput>();
      return ctx.services.users.create(input);
    },
  );

  OpenApiHelpers.mountJson(app, path: '/openapi.json');
  OpenApiHelpers.mountSwaggerUi(app, path: '/docs', specPath: '/openapi.json');
  app.mountMetricsEndpoint(observability: observability);

  await app.listen(port: 8080, workers: 1);
}

final class AppServices {
  AppServices() : users = UserStore();

  final UserStore users;
}

final class UserStore {
  int _nextId = 3;
  final List<UserDto> _users = <UserDto>[
    const UserDto(id: 'user-1', name: 'Ada Lovelace', email: 'ada@example.com'),
    const UserDto(id: 'user-2', name: 'Alan Turing', email: 'alan@example.com'),
  ];

  Future<List<UserDto>> list({String? search}) async {
    if (search case final term? when term.isNotEmpty) {
      return _users
          .where((user) => user.name.contains(term) || user.email.contains(term))
          .toList(growable: false);
    }

    return List<UserDto>.unmodifiable(_users);
  }

  Future<UserDto> create(CreateUserInput input) async {
    final duplicateEmail = _users.any((user) => user.email == input.email);
    if (duplicateEmail) {
      throw StateError('duplicate_email');
    }

    final user = UserDto(id: 'user-${_nextId++}', name: input.name, email: input.email);
    _users.add(user);
    return user;
  }
}

final class HealthResponse implements JsonEncodable {
  const HealthResponse({required this.status});

  final String status;

  @override
  Map<String, Object?> toJson() => {'status': status};
}

final class ListUsersQuery {
  const ListUsersQuery({this.search});

  factory ListUsersQuery.fromJson(Map<String, Object?> json) {
    return ListUsersQuery(search: json['search'] as String?);
  }

  final String? search;
}

final class ListUsersResponse implements JsonEncodable {
  const ListUsersResponse({required this.items});

  final List<UserDto> items;

  @override
  Map<String, Object?> toJson() => {
    'items': items.map((item) => item.toJson()).toList(growable: false),
  };
}

final class CreateUserInput {
  const CreateUserInput({required this.name, required this.email});

  factory CreateUserInput.fromJson(Map<String, Object?> json) {
    return CreateUserInput(name: json['name']! as String, email: json['email']! as String);
  }

  final String name;
  final String email;
}

final class UserDto implements JsonEncodable {
  const UserDto({required this.id, required this.name, required this.email});

  final String id;
  final String name;
  final String email;

  @override
  Map<String, Object?> toJson() => {'id': id, 'name': name, 'email': email};
}

final _schemaRegistry = JsonSchemaRegistry(
  schemas: <JsonSchema>[
    JsonSchema.object(
      id: 'HealthResponse',
      properties: <String, JsonSchema>{'status': JsonSchema.string()},
      required: <String>['status'],
    ),
    JsonSchema.object(
      id: 'ListUsersQuery',
      properties: <String, JsonSchema>{'search': JsonSchema.string()},
    ),
    JsonSchema.object(
      id: 'CreateUserInput',
      properties: <String, JsonSchema>{
        'name': JsonSchema.string(),
        'email': JsonSchema.string(format: 'email'),
      },
      required: <String>['name', 'email'],
    ),
    JsonSchema.object(
      id: 'UserDto',
      properties: <String, JsonSchema>{
        'id': JsonSchema.string(),
        'name': JsonSchema.string(),
        'email': JsonSchema.string(format: 'email'),
      },
      required: <String>['id', 'name', 'email'],
    ),
    JsonSchema.object(
      id: 'ListUsersResponse',
      properties: <String, JsonSchema>{'items': JsonSchema.array(items: JsonSchema.ref('UserDto'))},
      required: <String>['items'],
    ),
  ],
);

final _codecRegistry = DartHttpCodecRegistry.empty
    .withCodec<ListUsersQuery>(
      'ListUsersQuery',
      DartHttpCodec<ListUsersQuery>(
        encode: (value) => {'search': value.search},
        decode: (value) => ListUsersQuery.fromJson(_readObject(value)),
      ),
    )
    .withCodec<CreateUserInput>(
      'CreateUserInput',
      DartHttpCodec<CreateUserInput>(
        encode: (value) => {'name': value.name, 'email': value.email},
        decode: (value) => CreateUserInput.fromJson(_readObject(value)),
      ),
    );

Map<String, Object?> _readObject(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return {for (final entry in value.entries) '${entry.key}': entry.value};
  }

  throw StateError('Expected a JSON object, got ${value.runtimeType}.');
}
