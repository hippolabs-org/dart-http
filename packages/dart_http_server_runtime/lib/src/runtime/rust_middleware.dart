import 'open_telemetry_config.dart';

/// Declarative middleware entry consumed by the Rust transport layer.
///
/// Add these to [DartHttp.middlewares] to configure server-level behavior that
/// runs before a request reaches Dart route handlers.
final class RustMiddleware {
  const RustMiddleware._(this.name, [this.configuration]);

  /// Stable middleware identifier understood by the native runtime.
  final String name;

  /// Optional middleware-specific configuration payload.
  final RustMiddlewareConfiguration? configuration;

  /// Attaches or generates a request id for each request.
  static RustMiddleware requestId() => const RustMiddleware._('requestId');

  /// Enables tracing and optional OpenTelemetry export.
  static RustMiddleware tracing({OpenTelemetryConfig? openTelemetry}) {
    return RustMiddleware._(
      'tracing',
      RustTracingMiddlewareConfiguration(openTelemetry: openTelemetry),
    );
  }

  /// Configures basic CORS handling.
  static RustMiddleware cors({
    List<String> allowOrigins = const <String>[],
    List<String> allowHeaders = const <String>[],
  }) {
    return RustMiddleware._(
      'cors',
      RustCorsMiddlewareConfiguration(allowOrigins: allowOrigins, allowHeaders: allowHeaders),
    );
  }

  /// Enables response compression when the client supports it.
  static RustMiddleware compression() => const RustMiddleware._('compression');

  /// Rejects request bodies larger than [maxBytes].
  static RustMiddleware bodyLimit({required int maxBytes}) {
    return RustMiddleware._('bodyLimit', RustBodyLimitMiddlewareConfiguration(maxBytes: maxBytes));
  }
}

/// Typed configuration payload for a [RustMiddleware].
sealed class RustMiddlewareConfiguration {
  const RustMiddlewareConfiguration();
}

/// Configuration for the native tracing middleware.
final class RustTracingMiddlewareConfiguration extends RustMiddlewareConfiguration {
  const RustTracingMiddlewareConfiguration({this.openTelemetry});

  /// Optional OpenTelemetry export configuration.
  final OpenTelemetryConfig? openTelemetry;
}

/// Configuration for the native CORS middleware.
final class RustCorsMiddlewareConfiguration extends RustMiddlewareConfiguration {
  const RustCorsMiddlewareConfiguration({
    this.allowOrigins = const <String>[],
    this.allowHeaders = const <String>[],
  });

  /// Allowed CORS origins.
  final List<String> allowOrigins;

  /// Allowed CORS headers.
  final List<String> allowHeaders;
}

/// Configuration for the native request body limit middleware.
final class RustBodyLimitMiddlewareConfiguration extends RustMiddlewareConfiguration {
  const RustBodyLimitMiddlewareConfiguration({required this.maxBytes});

  /// Maximum accepted request body size in bytes.
  final int maxBytes;
}
