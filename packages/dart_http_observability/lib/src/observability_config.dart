import 'dart:io';

import 'structured_logger.dart';

/// Environment-backed configuration shared by the observability components.
final class ObservabilityConfig {
  const ObservabilityConfig({
    required this.serviceName,
    required this.serviceVersion,
    required this.environment,
    required this.logLevel,
    this.otlpTracesEndpoint,
    this.traceSampleRatio = 1,
    this.requestLoggingEnabled = true,
    this.includeErrorStacks = false,
  });

  factory ObservabilityConfig.fromEnvironment({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final runtimeEnvironment = env['ENVIRONMENT'] ?? 'development';
    return ObservabilityConfig(
      serviceName: env['SERVICE_NAME'] ?? 'dart-http-service',
      serviceVersion: env['SERVICE_VERSION'] ?? '0.0.0',
      environment: runtimeEnvironment,
      logLevel: LogLevel.parse(env['LOG_LEVEL']) ?? LogLevel.info,
      otlpTracesEndpoint: _nonEmpty(env['OTEL_EXPORTER_OTLP_TRACES_ENDPOINT']),
      traceSampleRatio: (double.tryParse(env['OTEL_TRACES_SAMPLER_ARG'] ?? '') ?? 1).clamp(0, 1),
      requestLoggingEnabled: _parseBool(env['REQUEST_LOGGING_ENABLED']) ?? true,
      includeErrorStacks: runtimeEnvironment == 'development' || runtimeEnvironment == 'dev',
    );
  }

  final String serviceName;
  final String serviceVersion;
  final String environment;
  final LogLevel logLevel;
  final String? otlpTracesEndpoint;
  final double traceSampleRatio;
  final bool requestLoggingEnabled;
  final bool includeErrorStacks;
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

bool? _parseBool(String? value) {
  return switch (value?.toLowerCase().trim()) {
    'true' || '1' || 'yes' || 'on' => true,
    'false' || '0' || 'no' || 'off' => false,
    _ => null,
  };
}
