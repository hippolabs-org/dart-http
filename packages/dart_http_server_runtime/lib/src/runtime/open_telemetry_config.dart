/// Configuration for middleware that exports OpenTelemetry spans.
final class OpenTelemetryConfig {
  const OpenTelemetryConfig.otlpGrpc({required this.serviceName, required this.endpoint});

  /// Service name reported to the collector.
  final String serviceName;

  /// OTLP gRPC endpoint, for example `http://localhost:4317`.
  final String endpoint;
}
