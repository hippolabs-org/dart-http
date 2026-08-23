import 'dart:async';

import '../http/http_method.dart';
import 'request_context.dart';

/// Normalized HTTP route metadata exposed to request observers.
final class HttpRequestObservation {
  const HttpRequestObservation({
    required this.method,
    required this.route,
    required this.operationId,
    required this.successStatusCode,
  });

  /// HTTP method accepted by the route.
  final HttpMethod method;

  /// Normalized route pattern, not the raw request URL.
  final String route;

  /// Stable route operation id.
  final String operationId;

  /// Declared success status for the route.
  final int successStatusCode;
}

/// Response metadata reported after the runtime writes a response.
final class HttpRequestObservationResult {
  const HttpRequestObservationResult({
    required this.statusCode,
    this.requestBodySize,
    this.responseBodySize,
  });

  final int statusCode;
  final int? requestBodySize;
  final int? responseBodySize;
}

/// First-class hook for observing all Dart-handled HTTP routes.
abstract interface class HttpRequestObserver<TServices> {
  FutureOr<HttpRequestObservationResult> observe({
    required RequestContext<TServices> context,
    required HttpRequestObservation request,
    required Future<HttpRequestObservationResult> Function() next,
  });
}
