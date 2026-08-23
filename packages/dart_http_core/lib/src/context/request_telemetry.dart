/// Telemetry hook associated with one request.
///
/// Route handlers can use this object to record domain events without taking a
/// direct dependency on the transport middleware implementation.
final class RequestTelemetry {
  const RequestTelemetry();

  /// Records an event for the current request.
  void addEvent(String event, {Map<String, Object?> attributes = const <String, Object?>{}}) {}
}
