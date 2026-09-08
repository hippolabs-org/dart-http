# dart_http_native_client

Asynchronous Rust HTTP transport for `dart_http_core`. A persistent Tokio and
reqwest runtime owns connection pooling, request cancellation, and response
streaming. Native Exchange bodies transfer ownership directly to Rust; network
response chunks remain native-owned until consumed or explicitly copied.

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
