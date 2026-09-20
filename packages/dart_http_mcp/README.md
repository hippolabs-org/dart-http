# dart_http_mcp

Mounts a `dart_mcp` server on the Rust-backed `dart_http_server` runtime using
the MCP 2026-07-28 Streamable HTTP transport.

The adapter preserves Dart HTTP route guards and request-scoped services. MCP
protocol validation, dispatch, JSON responses, request-scoped SSE responses,
subscriptions, body limits, and Origin validation remain owned by `dart_mcp`.

```dart
import 'package:dart_http_mcp/dart_http_mcp.dart';
import 'package:dart_http_server/dart_http_server.dart';
import 'package:dart_mcp/server.dart';

final app = DartHttp<AppServices>(services: AppServices.new);

app.mountMcp(
  '/mcp',
  serverFactory: (context) =>
      (channel) => AppMcpServer(channel, services: context.services),
  guards: [AppAuthorizationGuard()],
  allowedOrigins: const {'https://app.example.com'},
);
```

The current prerelease follows `dart_mcp` `0.6.0-wip`. Until that package is
published, workspace users must override `dart_mcp` to a compatible Git commit.
The Dart HTTP workspace pins the commit used for validation.

Authentication remains an application concern. Attach normal Dart HTTP guards
to the mounted endpoint and pass only deployment-approved origins.
