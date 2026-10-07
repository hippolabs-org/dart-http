# dart_http_client

HTTP and WebSocket transports for generated Dart HTTP clients.

Use this package from client applications that consume generated Dart HTTP API
clients. It provides concrete transport implementations backed by
`package:http` and `package:web_socket_channel`, while the shared generated
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
  const transport = DartHttpWebSocketClientTransport();

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
  connections through a single channel by default; `reconnect: true` opts into
  `package:web_socket_client`.
- `DartHttpWebSocketClient` adapts WebSocket messages to Dart HTTP's shared
  `WebSocketMessage` contract.

## Single-connection WebSockets

For protocols whose state belongs to one connection, use
`DartHttpWebSocketClientTransport()` (the default). It opens one channel and
never reconnects or replays messages. Peer closure ends the message stream;
`DartHttpClientCloseAwareWebSocket.closeDetails` exposes the terminal close
code/reason. HTTP headers and pings are supported on IO platforms; browser
WebSockets reject these capabilities explicitly. Initial frames remain available
until the first listener attaches. Failed or timed-out upgrades close their
channel, including a connection that finishes after the timeout.

Automatic reconnection is explicitly opt-in:

```dart
const transport = DartHttpWebSocketClientTransport(
  reconnect: true,
  backoff: ConstantBackoff(Duration(seconds: 1)),
);
```

Backoff and custom `socketFactory` options require `reconnect: true`. The single
connection path preserves timeout, ping and binary-type settings. The explicit
`DartHttpSingleConnectionWebSocketClientTransport` remains available when callers
want to require that policy independent of the standard transport's options.

## Migration from 0.1.x

Unconfigured transports now surface failed upgrades and peer EOF directly.
Handle errors/end-of-stream and deliberately restore application protocol state
when opening a replacement connection. Callers that depend on the previous
transparent retry/reconnect policy must explicitly set `reconnect: true`.
HTTP request behavior is unchanged.
