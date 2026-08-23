# dart_edge_http_server_runtime

Concrete HTTP runtime package for Dart Edge.

Use this package directly when you want the low-level Dart Edge API surface
without the higher-level HTTP server package. It re-exports the shared
contracts from `dart_edge_core`, but owns the concrete native server bridge,
route compilation, middleware configuration, and runtime request dispatch.

## Quick Start

```dart
import 'package:dart_edge_http_server_runtime/dart_edge_http_server_runtime.dart';

Future<void> main() async {
  final app = DartEdge<AppServices>(
    services: AppServices.new,
    openApiDocument: OpenApiDocument(
      title: 'Example API',
      version: '1.0.0',
    ),
  );

  app.get('/health', handler: (ctx) => const {'status': 'ok'});
  await app.listen(host: '0.0.0.0', port: 8080);
}

final class AppServices {
  const AppServices();
}
```

## OpenAPI Security

Declare named security schemes and global requirements on `OpenApiDocument`:

```dart
final app = DartEdge<AppServices>(
  services: AppServices.new,
  openApiDocument: OpenApiDocument(
    contact: const OpenApiContact(email: 'api@example.com'),
    license: const OpenApiLicense(name: 'MIT', identifier: 'MIT'),
    servers: const [
      OpenApiServer(
        url: 'https://api.example.com/{version}',
        variables: {
          'version': OpenApiServerVariable(
            defaultValue: 'v1',
            enumValues: ['v1', 'v2'],
          ),
        },
      ),
    ],
    tags: const [
      OpenApiTag(name: 'users', description: 'User operations.'),
    ],
    externalDocs: const OpenApiExternalDocumentation(
      url: 'https://docs.example.com',
    ),
    securitySchemes: const {
      'BearerAuth': OpenApiSecurityScheme.http(scheme: 'bearer'),
      'ApiKeyAuth': OpenApiSecurityScheme.apiKey(
        name: 'X-API-Key',
        in_: OpenApiApiKeyLocation.header,
      ),
    },
    security: [OpenApiSecurityRequirement.scheme('BearerAuth')],
  ),
);
```

This emits `components.securitySchemes.BearerAuth` and a global
`security: [{BearerAuth: []}]` requirement in the OpenAPI document.

For local-only development, omit `host:` and the runtime stays bound to
`127.0.0.1`. For deployment, pass a real bind address such as `0.0.0.0` or
`::`.

## Key Building Blocks

- `DartEdge` starts the native server and dispatches requests to registered
  routes
- `Router.get`, `post`, `put`, `patch`, `delete`, `head`, and `options` add
  inline HTTP handlers without writing a route class, with metadata grouped in
  `RouteOptions`
- `HttpRouteDefinition` is the main HTTP route base class from `dart_edge_core`
- `RouteOptions`, `RequestBody`, `ResponseSpec`, and `ResponseSet` describe the
  request and response shape in `dart_edge_core`
- `RequestContext` gives handlers access to services, decoded request values, and
  request-scoped extensions through `dart_edge_core`
- `WebSocketContext` gives WebSocket handlers typed text, JSON, binary, and
  mixed-frame streams plus matching send helpers
- `JsonSchema`, including `JsonSchema.ref`, and `JsonSchemaRegistry` connect the
  runtime to generated JSON Schema metadata through `dart_edge_core`
- `RustMiddleware` configures the transport-layer middleware stack

## Request Body Ergonomics

Handlers should use `ctx.req` for both decoded Dart payloads and native body
access:

```dart
app.post('/upload', handler: (ctx) async {
  final rawBody = ctx.req.nativeBody;
  final bytes = rawBody?.copyBytes();

  final form = await ctx.req.multipart();
  final file = form.files.single;
  return {'bytes': bytes?.length ?? file.length};
});
```

`nativeBody` is a borrowed view and is only valid while the current request is
being handled. Copy bytes if data needs to outlive the handler.

## WebSocket Frames

WebSocket routes can decode typed handshake query parameters and handle JSON
control messages, raw text, binary streams, or mixed protocols:

```dart
app.websocket(
  '/stream',
  options: const WebSocketOptions(query: JsonSchema.ref('StreamQuery')),
  onConnect: (socket) async {
    final query = socket.req.query<StreamQuery>();
    await socket.sendText('ready:${query.streamId}');

    await for (final frame in socket.messages.frames()) {
      switch (frame.kind) {
        case WebSocketMessageKind.text:
          await socket.sendJson({'echo': frame.text});
        case WebSocketMessageKind.binary:
          await socket.sendBinary(frame.bytes);
      }
    }
  },
);
```

For allocation-sensitive binary streams, take ownership of the native payload
and close it after all synchronous native consumers have borrowed its pointer:

```dart
await for (final payload in socket.messages.leasedBinary()) {
  try {
    final native = payload as NativeBinaryPayloadLease;
    waveform.addNativePcm16(
      pcm16LeBytesPtr: native.bytesPtr,
      byteLength: native.length,
    );
  } finally {
    payload.close();
  }
}
```

Reading `frame.bytes`, `messages.binary()`, WebTransport `datagrams()`, or
WebTransport `streams()` remains fully supported. Those compatibility APIs
copy a native lease lazily and release it immediately. WebTransport callers can
avoid the copy with `datagrams.leases()` and `streams.leases()`.

Text and JSON control frames are unchanged and can be mixed with leased binary
WebSocket frames through `messages.frames()`. Use `sendBinaryLease`,
`sendDatagramLease`, or `sendStreamLease` to send a native lease without a Dart
payload copy; normal text, JSON, and byte-list send methods remain available.

## Persistent WebTransport streams

Use the persistent stream API when one logical upload spans many chunks. It
emits peer-initiated streams when they open and exposes each received chunk as
a native lease instead of waiting for FIN and allocating one Dart `Uint8List`:

```dart
await for (final audio in transport.incomingStreams.unidirectional) {
  await for (final chunk in audio.leases()) {
    try {
      final native = chunk as NativeBinaryPayloadLease;
      waveform.addNativePcm16(
        pcm16LeBytesPtr: native.bytesPtr,
        byteLength: native.length,
      );
    } finally {
      chunk.close();
    }
  }
}
```

Servers can open a reliable sending stream with
`openUnidirectionalStream()` or a two-way control stream with
`openBidirectionalStream()`. `write()` completes after the native QUIC writer
has accepted every byte under congestion and flow control; `finish()` sends
FIN and waits for acknowledgment. `writeLease()` consumes a payload and can
borrow a native lease pointer without a Dart payload allocation. `reset()` and
receive-side `stop()` provide immediate cancellation with an application error
code. Runtime stream IDs and QUIC protocol stream IDs are both exposed.

The older `transport.streams.streams()` and `.leases()` APIs remain compatible
and still emit one completed unidirectional-stream payload. They are intended
for message-style traffic; allocation-sensitive streaming handlers should use
`incomingStreams`.

See [example/native_probe.dart](example/native_probe.dart) for the native asset
probe and [../dart_edge_http_server/example/simple_http_server.dart](../dart_edge_http_server/example/simple_http_server.dart)
for a larger application example that uses this runtime surface.

## Native binary responses

`NativeBinaryStreamResponse` transfers a `NativeByteStreamHandle` from another
native package directly into the Rust HTTP runtime. The runtime pulls one chunk
at a time on its blocking worker pool, propagates disconnect cancellation, and
never copies body chunks through Dart-managed memory. Use
`BinaryStreamResponse` when the producer is a normal Dart stream.

## Native Bindings

The low-level Dart FFI layer is generated with `package:ffigen`, not written by
hand.

- ABI header: `rust/include/dart_edge_http_server_runtime.h`
- Generated Dart bindings: `lib/src/native/generated_bindings.dart`
- Regenerate after ABI changes:

```sh
dart pub -C packages/dart_edge_http_server_runtime run ffigen --config tool/ffigen.yaml
```
