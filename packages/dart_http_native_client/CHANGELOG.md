## 0.2.17

- Expose the peer WebSocket close code and reason through the optional
  close-aware client capability.

## 0.2.16

- Drive streamed Reqwest response bodies directly on Tokio with demand-based
  backpressure, a shared completion port, and zero-copy Native Exchange chunk
  leases, avoiding the intermediate payload channel and blocking worker.
- Keep direct response readers strongly owned by their transport until normal
  completion or cancellation so idle SSE streams cannot lose their Dart
  completion target during garbage collection.
- Add `sendLeasedStream` for consumers that can process native-owned response
  chunks without materializing Dart byte arrays.

## 0.2.15

- Share one process-wide Rustls trust policy and TLS session cache between
  Reqwest HTTP requests and Tokio-Tungstenite WebSocket connections, while
  retaining protocol-appropriate ALPN settings for each transport.

## 0.2.14

- Restore single-shot native WebSocket opening semantics. Establishment remains
  bounded and cancellable, while reconnect policy stays with feature-level
  controllers that understand authentication and session lifecycle.

## 0.2.13

- Bound process-wide HTTP concurrency and cap each host's idle connection pool
  so a burst of parallel application startup requests cannot retain dozens of
  sockets alongside native WebSocket upgrades.
- Match Dart's 15-second idle connection lifetime instead of retaining the
  unlimited reqwest default pool for 90 seconds.

## 0.2.12

- Enable `TCP_NODELAY` explicitly for pooled HTTP connections and native
  WebSockets so latency-sensitive SSE events and control frames are not held
  for packet coalescing.
- Cover incremental SSE delivery before response completion.

## 0.2.11

- Report WebSocket opening failures only through the connection future instead
  of also enqueueing an error on a message stream that callers cannot yet
  observe.
- Retry transient native WebSocket transport failures within the original
  connection deadline, while leaving TLS, protocol, and HTTP failures final.

## 0.2.10

- Share one process-wide Tokio runtime, reqwest connection pool, and TLS client
  across transport handles, with optional asynchronous prewarming.
- Return buffered responses as Native Exchange leases and materialize Dart
  compatibility bytes lazily and at most once.
- Transfer Native Exchange request buffers directly into reqwest.
- Replace JSON response metadata with typed header descriptors.
- Add bounded fused-base64 WebSocket enqueueing and a native-owned base64 text
  stream pump with pause/resume and ordered flush fences.
- Keep Native Exchange response streams for explicitly streamed requests and
  advance the combined native ABI to version 9.

## 0.2.9

- Add fused native base64 text WebSocket sends for transferred Native Exchange
  buffers, avoiding large intermediate Dart strings and copies.

## 0.2.8

- Preserve stream ordering when text or binary frames are deferred before the
  first listener or while paused, delivering them before close and error.

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
