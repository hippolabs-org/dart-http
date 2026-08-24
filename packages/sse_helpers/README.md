# sse_helpers

Bounded, incremental Server-Sent Events encoding and decoding for ordinary Dart byte streams. The
package uses the protocol-level `SseEvent` from `dart_http_core`, without depending on an HTTP
transport or application framework.

```dart
final response = await client.sendStream(request);
await for (final event in decodeSseEvents(response.bodyStream)) {
  print('${event.event}: ${event.data}');
}
```

Use `SseDecodeLimits` to set memory bounds appropriate for the upstream service:

```dart
const limits = SseDecodeLimits(
  maxLineBytes: 64 * 1024,
  maxFrameBytes: 1024 * 1024,
  maxDataLines: 256,
  maxEventNameBytes: 256,
);

final events = decodeSseEvents(response.bodyStream, limits: limits);
```

The decoder accepts fragmented UTF-8 input, LF, CRLF, and CR line endings, multiline `data` and
comment fields, `id`, and valid non-negative `retry` hints. Unknown fields and invalid retry hints
are ignored as required by the SSE protocol. Malformed UTF-8 and configured limit violations raise
an `SseDecodeException` without including upstream payload contents.
