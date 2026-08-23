# dart_edge_http_server

App-facing HTTP server package for building Dart Edge services.

Import `package:dart_edge_http_server/dart_edge_http_server.dart` when you want the normal developer
experience: the shared contracts from `dart_edge_core`, the concrete runtime
from `dart_edge_http_server_runtime`, and app-facing helpers in one import.

## What You Get

- `DartEdge` and `Router` for starting the server and registering routes with
  `get`/`post`/`put`/`patch`/`delete` helpers, plus `routeGet`/`routePost`
  helpers for explicit route classes
- `RouteOptions` for inline handlers and `HttpRouteDefinition` for explicit
  route definitions
- `OpenApiHelpers` for mounting helper endpoints alongside your app
- WebSocket handlers with text, JSON, binary, and mixed-frame streams
- `dart_edge_shelf` and `dart_edge_jaspr` helpers for mounting Shelf and Jaspr
  apps
- `dart_edge_jaspr_helpers` components for reusable Jaspr-backed page and email
  scaffolds

## Quick Start

```dart
import 'package:dart_edge_http_server/dart_edge_http_server.dart';

Future<void> main() async {
  final app = DartEdge<AppServices>(
    services: AppServices.new,
    openApiDocument: OpenApiDocument(
      title: 'Example API',
      version: '1.0.0',
    ),
  );

  app.get('/health', handler: (ctx) => const {'status': 'ok'});
  OpenApiHelpers.mountJson(app, path: '/openapi.json');

  await app.listen(port: 8080);
}

final class AppServices {
  const AppServices();
}
```

See [example/simple_http_server.dart](example/simple_http_server.dart) for a
larger end-to-end example with nested routers, inline handlers, middleware, and
OpenAPI helper mounting.

## Request Bodies

Use `ctx.req` for decoded bodies, native body access, and multipart parsing:

```dart
app.post('/upload', handler: (ctx) async {
  final rawBody = ctx.req.nativeBody;
  final copied = rawBody?.copyBytes();

  final form = await ctx.req.multipart();
  final file = form.files.single;
  return {'bodyBytes': copied?.length ?? file.length};
});
```

`nativeBody` is a borrowed native view for the current request. Copy it before
storing it beyond the handler.

## WebSocket Routes

Use `WebSocketOptions.query` for typed handshake query parameters.
`messages.json<T>()` handles JSON text protocols, and `messages.binary()` or
`messages.frames()` handle raw binary data. Native hot paths can use
`messages.leasedBinary()` instead:

```dart
app.websocket(
  '/audio',
  options: const WebSocketOptions(query: JsonSchema.ref('AudioQuery')),
  onConnect: (socket) async {
    final query = socket.req.query<AudioQuery>();
    await socket.sendJson({'ready': true, 'room': query.room});

    await for (final bytes in socket.messages.binary()) {
      await socket.sendBinary(bytes);
    }
  },
);
```

WebTransport offers the same split: `datagrams()` and `streams()` return safe
Dart bytes, while `datagrams.leases()` and `streams.leases()` preserve native
payload ownership. JSON and text control messages continue through the normal
WebSocket methods.
