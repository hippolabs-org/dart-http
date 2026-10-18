/// What a transport actually measured; neither value confirms durable receipt.
enum DartHttpClientUploadMeasurement {
  /// Browser upload events report transmission of the request body.
  transmitted,

  /// The native networking engine consumed body bytes under backpressure.
  /// Socket/TLS buffering can still be ahead of the peer.
  transportConsumed,
}

/// Cumulative body progress for one HTTP attempt, excluding headers.
///
/// Source reads and enqueueing bytes must not emit these events. Transports
/// without a measurement leave the callback silent. Callbacks run on the
/// caller's isolate and must not throw.
final class DartHttpClientUploadProgress {
  const DartHttpClientUploadProgress({
    required this.bytes,
    required this.measurement,
    this.totalBytes,
  });

  final int bytes;
  final int? totalBytes;
  final DartHttpClientUploadMeasurement measurement;
}
