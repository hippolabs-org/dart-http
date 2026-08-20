/// The kind of malformed or oversized input encountered by an SSE decoder.
enum SseDecodeErrorCode {
  invalidByte,
  invalidUtf8,
  lineTooLarge,
  frameTooLarge,
  dataLineLimitExceeded,
  eventNameTooLarge,
}

/// Payload-safe failure raised while decoding a Server-Sent Events stream.
final class SseDecodeException implements Exception {
  const SseDecodeException({required this.code, required this.message});

  final SseDecodeErrorCode code;
  final String message;

  @override
  String toString() => 'SseDecodeException(${code.name}): $message';
}
