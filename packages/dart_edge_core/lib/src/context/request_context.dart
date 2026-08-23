import 'request_input.dart';
import 'request_telemetry.dart';
import 'response_builder.dart';

/// Per-request context passed to a route handler.
///
/// It gives handlers access to app services, decoded request values, telemetry,
/// and request-scoped extensions populated by guards or surrounding code.
final class RequestContext<TServices> {
  RequestContext({
    required this.services,
    this.req = RequestInput.empty,
    this.telemetry = const RequestTelemetry(),
  });

  /// Fresh services instance for the current request.
  final TServices services;

  /// Decoded request params, query, headers, and body.
  final RequestInput req;

  /// Mutable response builder used to shape the outgoing response.
  final ResponseBuilder res = ResponseBuilder();

  /// Telemetry hook associated with this request.
  final RequestTelemetry telemetry;
  final Map<Type, Object?> _extensions = <Type, Object?>{};

  /// Reads a required request-scoped extension of type [T].
  T require<T>() {
    final value = maybe<T>();
    if (value == null) {
      throw StateError('Missing request-scoped value for $T.');
    }
    return value;
  }

  /// Reads an optional request-scoped extension of type [T].
  T? maybe<T>() => _extensions[T] as T?;

  /// Stores a request-scoped extension by its runtime type.
  void put<T>(T value) {
    _extensions[T] = value;
  }
}
