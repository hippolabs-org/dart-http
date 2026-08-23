# dart_http_client

HTTP and WebSocket transports for generated Dart HTTP clients.

Use this package from client applications that consume generated Dart HTTP API
clients. It provides concrete transport implementations backed by
`package:http` and `package:web_socket_client`, while the shared generated
client contracts live in `dart_http_core`.

## Quick Start

```dart
import 'package:dart_http_core/dart_http_core.dart';
import 'package:dart_http_client/dart_http_client.dart';

Future<void> main() async {
  final transport = DartHttpClientTransport(
    interceptors: [
      DartHttpBearerTokenInterceptor(() async => 'access-token').call,
    ],
  );

  try {
    final response = await transport.send(
      DartHttpClientRequest(
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
import 'package:dart_http_core/dart_http_core.dart';
import 'package:dart_http_client/dart_http_client.dart';

Future<void> main() async {
  const transport = DartHttpWebSocketClientTransport(
    backoff: ConstantBackoff(Duration(seconds: 1)),
  );

  final socket = await transport.connect(
    DartHttpClientWebSocketRequest(
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

- `DartHttpClientTransport` sends generated HTTP client requests through
  `package:http`.
- `DartHttpClientInterceptor` wraps HTTP requests for auth, tracing, retries,
  or other cross-cutting client concerns.
- `DartHttpBearerTokenInterceptor` adds an `Authorization: Bearer <token>`
  header when a token is available.
- `DartHttpWebSocketClientTransport` opens generated WebSocket client
  connections through `package:web_socket_client`.
- `DartHttpWebSocketClient` adapts WebSocket messages to Dart HTTP's shared
  `WebSocketMessage` contract.
