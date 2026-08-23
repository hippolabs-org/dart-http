# dart_edge_http_client

HTTP and WebSocket transports for generated Dart Edge clients.

Use this package from client applications that consume generated Dart Edge API
clients. It provides concrete transport implementations backed by
`package:http` and `package:web_socket_client`, while the shared generated
client contracts live in `dart_edge_core`.

## Quick Start

```dart
import 'package:dart_edge_core/dart_edge_core.dart';
import 'package:dart_edge_http_client/dart_edge_http_client.dart';

Future<void> main() async {
  final transport = DartEdgeHttpClientTransport(
    interceptors: [
      DartEdgeBearerTokenInterceptor(() async => 'access-token').call,
    ],
  );

  try {
    final response = await transport.send(
      DartEdgeClientRequest(
        method: HttpMethod.get,
        uri: Uri.parse('https://api.example.test/health'),
      ),
    );

    print(response.status);
    print(response.body);
  } finally {
    transport.close();
  }
}
```

## WebSockets

```dart
import 'package:dart_edge_core/dart_edge_core.dart';
import 'package:dart_edge_http_client/dart_edge_http_client.dart';

Future<void> main() async {
  const transport = DartEdgeWebSocketClientTransport(
    backoff: ConstantBackoff(Duration(seconds: 1)),
  );

  final socket = await transport.connect(
    DartEdgeClientWebSocketRequest(
      uri: Uri.parse('wss://api.example.test/events'),
    ),
  );

  await socket.sendJson({'type': 'subscribe'});
  await for (final message in socket.messages) {
    print(message.text);
  }
}
```

## Main Types

- `DartEdgeHttpClientTransport` sends generated HTTP client requests through
  `package:http`.
- `DartEdgeClientInterceptor` wraps HTTP requests for auth, tracing, retries,
  or other cross-cutting client concerns.
- `DartEdgeBearerTokenInterceptor` adds an `Authorization: Bearer <token>`
  header when a token is available.
- `DartEdgeWebSocketClientTransport` opens generated WebSocket client
  connections through `package:web_socket_client`.
- `DartEdgeWebSocketClient` adapts WebSocket messages to Dart Edge's shared
  `WebSocketMessage` contract.
