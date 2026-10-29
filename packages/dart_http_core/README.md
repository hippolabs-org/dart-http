# dart_http_core

Transport-agnostic core contracts for Dart HTTP.

Use this package when you need the shared request, response, routing, HTTP, and
WebSocket contract surface without depending on a concrete server runtime.
Most app code should import an app-facing package such as
`dart_http_server` instead. `dart_http_core` is the lower-level package
for adapters, tooling, code generation, and packages that need to share the
same contract model.

## What You Get

- `RequestContext`, `RequestInput`, `RequestTelemetry`, and `ResponseBuilder`
  for handler-facing request state
- `Router`, `RouteRegistry`, `RouteOptions`, and `Guard`
  for transport-agnostic route registration
- `RouteOptions`, `ResponseSpec`, `RequestBody`, `ErrorResponse`, and
  `HttpMethod` for explicit HTTP contracts
- `JsonEncodable`, `JsonSchema`, and `JsonSchemaRegistry` for schema-driven
  request and response metadata
- `WebSocketOptions`, `WebSocketContext`, `WebSocketMessage`, and related route
  definitions for text, JSON, binary, and ownership-transferring WebSocket
  payloads, including reusable prefixes for native framed sends
- `WebTransportContext` plus persistent unidirectional and bidirectional stream
  contracts with incremental binary payload leases
- `GenerateHttpModel` for public schema-derived model declarations
- Reusable typed client operations and immutable endpoint definitions, including
  request handles, cancellation, timeout, binary/SSE streaming and upload progress

## Generated models and client operations

With `dart_http_server_codegen` 0.6.0 or newer, annotate const schema declarations
using `@GenerateHttpModel(name: 'CreateUserBody')`. The generated class is public,
so a body can be constructed using `.new(...)` from another library when its
contextual type is known. Legacy `FromHttpSchema` typedef models remain supported.

Generated clients reuse core operation classes for common argument signatures:
`DartHttpJsonBodyOperation<Body, Response>`, `DartHttpJsonQueryOperation<Query, Response>`,
binary and SSE variants, multipart uploads, and realtime connections. Each
operation exposes only the capabilities appropriate to its signature. Ordinary
JSON operations have `call`, `start`, and `info`; binary operations also have
`stream`. Multipart uploads retain `onUploadProgress`.

Endpoint definitions hold metadata and codecs once. Operations hold no mutable
request state; each `start` returns an independent `DartHttpClientRequestHandle`.
Opening a streamed response completes its handle's future; consuming or closing
its body remains the caller's responsibility, as with direct `invokeStream`.

See the [codegen guide](../dart_http_server_codegen/README.md) for public model
declarations, migration and the legacy client generation option.

## Quick Start

```dart
import 'package:dart_http_core/dart_http_core.dart';

Future<void> main() async {
  final router = Router<AppServices>(tags: const ['system']);

  router.get<Map<String, String>>(
    '/health',
    options: RouteOptions(
      summary: 'Health check',
      success: ResponseSpec.json(),
    ),
    handler: (ctx) => {'status': 'ok'},
  );

  final registration = router.routeRegistry.registrations.single;
  print(registration);

  final api = Router<AppServices>();
  api.get('/users', handler: (ctx) => const <Map<String, Object?>>[]);
  router.mountRouter('/api', api, tags: const ['api']);
}

final class AppServices {
  const AppServices();
}
```

This package only models the shared contracts. It does not open sockets, accept
connections, or execute a concrete HTTP runtime by itself.

Native JSON audio extraction (client native ABI 17): opt into
`DartHttpClientJsonBinaryWebSocket.setJsonBase64Decoding` with generic
`WebSocketJsonBase64Rule` selectors. RFC 6901 pointers support `*` for array
items and optional root string-value/prefix matching. Selected base64 fields
become null in JSON metadata; `WebSocketMessage.takeJsonBinaryLeases()`
transfers owning payloads keyed by concrete pointer once. Close the message
to release unclaimed payloads. Invalid selected base64 is a transport error.
Unselected control frames keep their original JSON. This layer contains no
provider-specific protocol rules. Update the native asset with the Dart API.
