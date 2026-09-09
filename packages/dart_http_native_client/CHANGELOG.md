## 0.2.7

- Advance the native ABI for byte-stream boundary statistics.

## 0.2.6

- Return exact native chunk and byte counters from byte-stream boundary fences.

## 0.2.5

- Add a bounded, synchronous native WebSocket lease enqueue that transfers
  buffer ownership without a Dart completion round trip per message.
- Add an ordered WebSocket flush fence for segment-boundary synchronization.
- Add a native byte-stream pump that frames and sends every producer chunk
  without per-chunk Dart objects or completion callbacks.

## 0.2.4

- Publish native assets for Android arm, arm64, and x64; iOS arm64 devices and
  arm64/x64 simulators; macOS arm64/x64; Linux arm64/x64; and Windows arm64/x64.
- Add Windows runtime smoke coverage for the HTTP and WebSocket transport.

## 0.2.3

- Add ownership-transferring outbound WebSocket binary frames backed by Native
  Exchange buffers.
- Allow a reusable Dart prefix and an adopted native payload to be sent as one
  fragmented WebSocket message without concatenating the payload in Dart.
- Advance the native ABI to version 4 for the adopted-buffer send entry point.

## 0.2.2

- Use `hippolabs_native_assets` 0.1.2 so precompiled artifacts are reused from
  Dart's shared hook output instead of copied into build-specific directories.

## 0.2.1

- Update Native Exchange dependencies to the latest release line.

## 0.2.0

- Implement the generated-client WebSocket transport with Tokio/tungstenite.
- Preserve incoming binary frames as Native Exchange leases.
- Add bounded incoming/outgoing queues, Dart pause/resume backpressure,
  subprotocol and header negotiation, graceful close, and immediate abort.

## 0.1.0

- Add a persistent Tokio/reqwest HTTP client with asynchronous completion
  ports, cancellation, streamed responses, and Native Exchange request bodies.
