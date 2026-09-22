# dart_http_shelf

Mount existing Shelf handlers on a Dart HTTP `Router` without replacing the
application's HTTP runtime.

```dart
import 'package:dart_http_server/dart_http_server.dart';
import 'package:dart_http_shelf/dart_http_shelf.dart';
import 'package:shelf/shelf.dart' as shelf;

final app = DartHttp<void>(services: () {});

app.mountShelfHandler(
  (request) => shelf.Response.ok('Hello from Shelf'),
  path: '/legacy/<legacyPath*>',
  methods: const [HttpMethod.get],
  handlerPath: '/legacy',
);
```

Requests retain their method, path, query, headers, and buffered body. Shelf
response bodies are forwarded as backpressured Dart HTTP streams. Routes are
hidden from generated clients and OpenAPI by default; provide `routeOptions`
when different metadata is required.
