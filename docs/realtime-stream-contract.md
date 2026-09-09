# Realtime stream contract

All Dart HTTP realtime transports implement the same delivery semantics,
whether their payload storage is Native Exchange, Dart-owned, or browser-owned.

## Required invariants

- Data frames are delivered in wire order.
- Frames received before the first listener are retained.
- A paused consumer applies bounded native or socket-level backpressure.
- Close and error are observed only after every preceding data frame.
- A send future or flush fence means the transport has stopped borrowing the
  payload; peer delivery requires an application acknowledgement.
- Every transferred payload has exactly one owner and is released exactly once.

Native Exchange is the preferred ownership boundary on Dart VM platforms.
Browser transports cannot use `dart:ffi`, but must preserve the same ordering
and terminal-delivery behavior with browser-owned buffers.

## Application-level losslessness

WebSocket and TCP ordering applies only to a live connection. Protocols that
must survive reconnects need sequence numbers, cumulative acknowledgements,
and a bounded replay window. Producers retain unacknowledged payloads until an
ACK advances the window; reconnect resumes from the first unacknowledged
sequence. A durable outbox or recording is the fallback when the replay window
cannot be retained.

## Conformance cases

Every transport implementation should cover:

1. An immediate server frame before the application attaches a listener.
2. Interleaved text and binary frames followed by immediate peer close.
3. Paused consumption followed by data and close, then resume.
4. A full bounded ingress queue that resumes after the consumer drains.
5. A full bounded egress queue with deterministic ownership release.
6. Cancellation and error paths with exactly-once lease release.
