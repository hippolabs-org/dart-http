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
