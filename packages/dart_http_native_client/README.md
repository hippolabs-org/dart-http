# dart_http_native_client

Asynchronous Rust HTTP transport for `dart_http_core`. A persistent Tokio and
reqwest runtime owns connection pooling, request cancellation, and response
streaming. Native Exchange bodies transfer ownership directly to Rust; network
response chunks remain native-owned until consumed or explicitly copied.

The Tokio runtime, TLS configuration, and reqwest connection pool are initialized
once per process. Opening a transport clones the shared client handle. Apps may
start that work early, but normal opening performs the same initialization when
needed:

```dart
await NativeHttpClientRuntime.prewarm();
final transport = await NativeHttpClientTransport.open();
```

The package ships native assets for Android (arm, arm64, and x64), iOS devices
and simulators, Linux, macOS, and Windows. It requires `dart:ffi` and therefore
does not support web builds.

```dart
final transport = await NativeHttpClientTransport.open();
final response = await transport.sendStream(request);
await for (final chunk in response.bodyStream) {
  // Copied compatibility stream.
}
transport.close();
```

Use `sendNative` when the consumer can keep the response body in Native
Exchange instead of materializing chunks in the Dart heap.

Use `sendLeased` for a buffered native-owned body. The lease must be closed or
transferred. Ordinary `send` wraps the same lease and creates Dart bytes only
when `bodyBytes` is requested:

```dart
final response = await transport.sendLeased(request);
try {
  consume(response.body.bytesView);
} finally {
  response.close();
}
```

Requests accept a `bodyLease` as well. A transferable Native Exchange lease
moves directly into reqwest without allocating payload-sized Dart storage.

The same transport implements `DartHttpClientWebSocketTransport`. Incoming
binary frames remain Native Exchange leases until the consumer copies,
transfers, or closes them:

```dart
final socket = await transport.connect(
  DartHttpClientWebSocketRequest(uri: Uri.parse('wss://example.com/realtime')),
);
await for (final message in socket.messages) {
  if (message.kind == WebSocketMessageKind.binary) {
    final lease = message.takeBinaryLease();
    try {
      consume(lease.bytesView);
    } finally {
      lease.close();
    }
  }
}
```

Incoming and outgoing queues are bounded. Pausing the Dart stream subscription
stops native receive draining and applies socket backpressure. Queue capacities
can be configured with `webSocketIncomingCapacity` and
`webSocketOutgoingCapacity` when opening the transport.

Outbound Native Exchange buffers can also move directly into the native send
queue. The send consumes the lease on success or failure, and completes once
the transport no longer owns the payload:

```dart
await socket.sendBinaryLease(BinaryPayloadLease.fromByteLease(nativeLease));
```

For protocols with a small header followed by a native payload, pass a reusable
prefix. The native client sends the two buffers as fragments of one logical
WebSocket message, so Dart never concatenates the payload:

```dart
await socket.sendBinaryLease(
  BinaryPayloadLease.fromByteLease(nativeLease),
  prefix: reusableHeader,
);
```

Portable WebSocket transports support the same helper through a safe copying
fallback.

Protocols that require base64 inside a text frame can encode and frame a
transferred native payload without creating the base64 or enclosing message as
Dart strings:

```dart
await socket.sendTextBase64Lease(
  BinaryPayloadLease.fromByteLease(nativeLease),
  prefix: '{"type":"input_audio_buffer.append","audio":"',
  suffix: '"}',
);
```

The native transport performs one allocation for the final UTF-8 message. The
portable fallback uses Dart's standard padded base64 encoder.

Realtime producers can avoid a completion future for every frame by using the
bounded native queue and one ordered fence per logical segment:

```dart
final queued = socket as DartHttpClientQueuedWebSocket;
queued.enqueueTextBase64Lease(
  BinaryPayloadLease.fromByteLease(nativeLease),
  prefix: '{"type":"input_audio_buffer.append","audio":"',
  suffix: '"}',
);
await queued.flush();
```

When the producer already exposes a Native Exchange byte stream, the native
stream pump keeps every chunk, base64 allocation, and WebSocket enqueue outside
Dart. Dart only controls segment boundaries:

```dart
final nativeSocket = socket as DartHttpClientNativeStreamWebSocket;
final pump = nativeSocket.adoptBase64TextStream(nativeStream);
pump.resume(
  prefix: '{"type":"input_audio_buffer.append","audio":"',
  suffix: '"}',
);
final stats = await pump.pauseAndFlush();
```

Compare the Dart and fused-native paths over a loopback WebSocket with:

```sh
dart run benchmark/websocket_base64_send_benchmark.dart
```
