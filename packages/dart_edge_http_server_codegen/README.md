# dart_edge_http_server_codegen

Build-time JSON Schema model generation and client-generation APIs for Dart
Edge HTTP.

This package provides a `build_runner` builder for schema-inferred Dart model
types plus lower-level client generator APIs for tooling that already has
normalized HTTP route metadata.

## Core Concepts

- `FromSchema` generates a Dart model class from a const `JsonSchema` and is
  exported by `dart_edge_core` and the app-facing `dart_edge_http_server`
- `JsonSchemaRegistry` references can be supplied to validate `$ref` usage
- `FromSchema.responseStatus` controls the generated JSON `ResponseSpec`
  status, defaulting to `200`
- `DartEdgeClientGenerator` emits Dart client classes from normalized route
  metadata
- `DartEdgeHttpClientBase` is exported by `dart_edge_core`
- `dart_edge_http_client` provides concrete `package:http` and
  `web_socket_client` transports for generated clients

`dart_edge_http_server_codegen` does not export `FromSchema`. Import
annotations and runtime contracts from `dart_edge_core` or the app-facing
`dart_edge_http_server` package.

## Schema Model Generation

Add this package and `build_runner` as development dependencies. The
annotations are imported from the app-facing server package.

```yaml
dependencies:
  dart_edge_http_server: ^0.3.2

dev_dependencies:
  build_runner: ^2.15.1
  dart_edge_http_server_codegen: ^0.3.3
```

Define const schemas and type aliases:

```dart
import 'package:dart_edge_http_server/dart_edge_http_server.dart';

part 'users.g.dart';

const createUserInputSchema = JsonSchema.object(
  id: 'CreateUserInput',
  properties: <String, JsonSchema>{
    'name': JsonSchema.string(),
    'email': JsonSchema.string(format: 'email'),
  },
  required: <String>['name', 'email'],
  additionalProperties: false,
);

const userSchemas = JsonSchemaRegistry(
  schemas: <JsonSchema>[createUserInputSchema],
);

@FromSchema(createUserInputSchema, registry: userSchemas)
typedef CreateUserInput = _$CreateUserInput;
```

Run generation:

```sh
dart run dart_edge_http_server_codegen:build
```

The generated part emits the private backing class used by the public typedef:

```dart
final class _$CreateUserInput {
  const _$CreateUserInput({required this.name, required this.email});

  static const schemaId = 'CreateUserInput';

  static const JsonSchema schema = JsonSchema.object(
    id: schemaId,
    properties: <String, JsonSchema>{
      'name': JsonSchema.string(),
      'email': JsonSchema.string(format: 'email'),
    },
    required: <String>['name', 'email'],
  );

  static const schemaRef = JsonSchema.componentRef(schemaId);

  static const RequestBody requestBody = RequestBody.json(
    schema: schema,
    decoder: fromJson,
  );

  static const ResponseSpec response = ResponseSpec.json(
    status: 200,
    schema: schema,
  );

  final String name;
  final String email;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'email': email,
  };

  static CreateUserInput fromJson(Object? value) {
    // ...
  }
}
```

## Client Generation

`dart_edge_http_server_codegen` emits one typed operation object per HTTP,
WebSocket, and WebTransport route. Operation objects expose stable route
metadata and keep ordinary HTTP calls concise:

```dart
final info = client.createRecording.info;
final response = await client.createRecording(body: request);
final started = client.createRecording.start(body: request);
started.cancel();

final socket = await client.recordingEvents.connect();
final transport = await client.recordingTransport.connect();
```

HTTP operation objects are callable, so `client.createRecording(...)` delegates
to `client.createRecording.call(...)`. `start(...)` begins the same request and
returns a `DartEdgeClientRequestHandle` with lifecycle state and cancellation.
WebSocket and WebTransport operation objects expose `connect(...)` because the
connected socket/session is already their long-lived lifecycle handle.

Binary response operations generate both a callable buffered operation and a
`stream(...)` method. Use the buffered call when the complete
`Uint8List` is convenient, or consume the streamed response incrementally for
large downloads:

```dart
final response = await client.getRecording.stream(body: request);
await for (final chunk in response.bodyStreamWithProgress(
  onProgress: (progress) {
    print('${progress.bytesReceived}/${progress.totalBytes ?? '?'}');
  },
)) {
  sink.add(chunk);
}
```

The progress helper reads `Content-Length` when available. Applications remain
responsible for presenting progress, choosing storage, and handling lifecycle
states such as preparing, saving, completion, and cancellation.
