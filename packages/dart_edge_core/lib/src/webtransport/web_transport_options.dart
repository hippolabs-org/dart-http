import '../router/route_exposure.dart';

/// Convenience options for inline `Router.webtransport` handlers.
final class WebTransportOptions {
  const WebTransportOptions({
    this.operationId,
    this.summary,
    this.tags = const <String>[],
    this.deprecated = false,
    this.exposure = RouteExposure.all,
    this.maxPendingMessages = 256,
    this.maxPendingBytes = 8 * 1024 * 1024,
  });

  /// Optional stable identifier used in generated output and manifests.
  final String? operationId;

  /// Optional short summary for documentation.
  final String? summary;

  /// Tags attached to the route in generated documentation.
  final List<String> tags;

  /// Whether the route should be marked as deprecated.
  final bool deprecated;

  /// Generated surfaces this route should appear in.
  final RouteExposure exposure;

  /// Maximum number of queued datagrams, stream payloads, or stream chunks.
  final int maxPendingMessages;

  /// Maximum queued bytes per session or persistent receive stream.
  final int maxPendingBytes;

  /// Returns a normalized options object suitable for runtime execution.
  WebTransportOptions normalized({String? defaultOperationId}) {
    final resolvedOperationId = operationId ?? defaultOperationId;
    if (resolvedOperationId == null) {
      throw ArgumentError.value(
        this,
        'options',
        'WebTransportOptions.operationId is required for WebTransport routes.',
      );
    }
    RangeError.checkValueInInterval(maxPendingMessages, 1, 1 << 20, 'maxPendingMessages');
    RangeError.checkValueInInterval(maxPendingBytes, 1, 1 << 40, 'maxPendingBytes');

    return WebTransportOptions(
      operationId: resolvedOperationId,
      summary: summary,
      tags: List<String>.unmodifiable(tags),
      deprecated: deprecated,
      exposure: exposure,
      maxPendingMessages: maxPendingMessages,
      maxPendingBytes: maxPendingBytes,
    );
  }
}
