# dart_edge_core

Transport-agnostic core contracts for Dart Edge.

Use this package when you need the shared request, response, routing, HTTP, and
WebSocket contract surface without depending on a concrete server runtime.
Most app code should import an app-facing package such as
`dart_edge_http_server` instead. `dart_edge_core` is the lower-level package
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
  definitions for text, JSON, and binary WebSocket routes
- `WebTransportContext` plus persistent unidirectional and bidirectional stream
  contracts with incremental binary payload leases

## Quick Start

```dart
import 'package:dart_edge_core/dart_edge_core.dart';

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
