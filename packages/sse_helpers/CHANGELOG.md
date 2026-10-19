## 0.1.2

- Decode by scanning each chunk for line breaks and decoding lines straight
  from `Uint8List` views; only lines spanning chunks are buffered. CRLF split
  across chunks, BOM stripping, limits and invalid-byte errors are unchanged.
- Require `dart_http_core` 0.4.0.

## 0.1.1

- Use the `SseEvent` type from `dart_http_core`.

## 0.1.0

- Add bounded, incremental decoding of server-sent event byte streams into Dart HTTP `SseEvent` values.
