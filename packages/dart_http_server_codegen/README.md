# dart_http_server_codegen

Build-time JSON Schema model generation and client-generation APIs for Dart
HTTP.

This package provides a `build_runner` builder for schema-inferred Dart model
types plus lower-level client generator APIs for tooling that already has
normalized HTTP route metadata.

## Core Concepts

- `FromHttpSchema` generates a Dart model class from a const `JsonSchema` and is
  exported by `dart_http_core` and the app-facing `dart_http_server`
- `JsonSchemaRegistry` references can be supplied to validate `$ref` usage
- `FromHttpSchema.responseStatus` controls the generated JSON `ResponseSpec`
  status, defaulting to `200`
- `DartHttpClientGenerator` emits Dart client classes from normalized route
  metadata
- `DartHttpClientBase` is exported by `dart_http_core`
- `dart_http_client` provides concrete `package:http` and
  `web_socket_channel` transports for generated clients

`dart_http_server_codegen` does not export `FromHttpSchema`. Import
annotations and runtime contracts from `dart_http_core` or the app-facing
`dart_http_server` package.

## Public model generation

Use `dart_http_core` 0.4.1 or newer and this generator 0.6.0 or newer. Annotate
const schema declarations directly:

```dart
import 'package:dart_http_core/dart_http_core.dart';
import 'package:json_schema/json_schema.dart';

part 'users.g.dart';

@GenerateHttpModel(name: 'CreateUserBody', responseStatus: 201)
const createUserBodySchema = JsonSchema.object(
  id: 'CreateUserInput',
  properties: {'name': JsonSchema.string()},
  required: ['name'],
);

CreateUserBody initialBody() => .new(name: 'Alice');
```

Run `dart run build_runner build`. The part declares the public `CreateUserBody`
class directly, including its constructor, `decode`, `fromJson`, `toJson`,
`schemaId`, `schema`, `schemaRef`, `requestBody` and `response` helpers. Scalar
query models also keep `decodeQuery`. Set `source: HttpModelSource.multipart`
for inbound multipart models. `registry` and `refs` work as for legacy models.

Public names must be unique in the library. A schema constant has no Dart type
parameters; existing generic typedef models remain supported in legacy form.
When migrating references to generated types, generate public declarations
before removing temporary unannotated aliases, then regenerate and analyze.

## Shared client operations

Clients use predefined operation classes from `dart_http_core` for common JSON,
binary, multipart and SSE signatures, plus query-based WebSocket and simple
WebTransport connections. Generated code retains endpoint metadata and codecs;
it no longer repeats execution and handle logic for every matching endpoint.
Uncommon combinations retain endpoint-specific adapters.

Normal call sites stay the same:

```dart
final response = await client.createUser(body: .new(name: 'Alice'));
final handle = client.createUser.start(body: .new(name: 'Alice'));
final metadata = client.createUser.info;
handle.cancel();
final streamed = await client.download.stream(query: downloadQuery);
```

Binary operations expose `.stream`; multipart operations expose upload progress.
Required body arguments remain required and missing capabilities remain absent.

**Migration:** endpoint-specific operation classes and constructors are public
APIs and change under the new default. Consumers that explicitly name or
instantiate them can retain the previous output using:

```dart
const DartHttpClientGenerationOptions(useSharedOperations: false)
```

Pass these options to `DartHttpClientLibrarySpec.fromRouter`. For a directly
constructed spec, set `useSharedOperations: false` on the spec itself.

## Legacy schema model generation

Add this package and `build_runner` as development dependencies. The
annotations are imported from the app-facing server package.

```yaml
dependencies:
  dart_http_server: ^0.4.0

dev_dependencies:
  build_runner: ^2.16.2
  dart_http_server_codegen: ^0.6.0
```

Define const schemas and type aliases:

```dart
import 'package:dart_http_server/dart_http_server.dart';

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

@FromHttpSchema(createUserInputSchema, registry: userSchemas)
typedef CreateUserInput = _$CreateUserInput;
```

Run generation:

```sh
dart run dart_http_server_codegen:build
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

## Schema Query Decoding

Object models generated from `@FromHttpSchema` expose `decodeQuery` when every
field is a string, integer, number, or boolean schema. Use it as a route's
`queryDecoder` to convert URL strings before calling the generated JSON model
decoder:

```dart
RouteOptions(
  query: listQuerySchema,
  queryDecoder: ListQuery.decodeQuery,
);
```

Invalid scalar values and schema range violations produce HTTP 400. Array and
object query parameters need a defined multi-value wire encoding and continue
to use a route-specific decoder.

## Client Generation

`dart_http_server_codegen` emits one typed operation object per HTTP,
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
returns a `DartHttpClientRequestHandle` with lifecycle state and cancellation.
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
