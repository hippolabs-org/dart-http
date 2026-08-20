/// Memory bounds applied while decoding one Server-Sent Events stream.
final class SseDecodeLimits {
  const SseDecodeLimits({
    this.maxLineBytes = 1024 * 1024,
    this.maxFrameBytes = 1024 * 1024,
    this.maxDataLines = 256,
    this.maxEventNameBytes = 256,
  });

  /// Maximum encoded bytes accepted before one line ending.
  final int maxLineBytes;

  /// Maximum encoded bytes retained for the fields of one event frame.
  final int maxFrameBytes;

  /// Maximum number of `data` fields retained in one event frame.
  final int maxDataLines;

  /// Maximum encoded bytes accepted for the value of an `event` field.
  final int maxEventNameBytes;

  /// Throws when any configured limit is not positive.
  void validate() {
    _requirePositive(maxLineBytes, 'maxLineBytes');
    _requirePositive(maxFrameBytes, 'maxFrameBytes');
    _requirePositive(maxDataLines, 'maxDataLines');
    _requirePositive(maxEventNameBytes, 'maxEventNameBytes');
  }
}

void _requirePositive(int value, String name) {
  if (value <= 0) {
    throw ArgumentError.value(value, name, 'Must be greater than zero.');
  }
}
