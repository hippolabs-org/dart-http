import 'dart:async';
import 'dart:math';

/// Correlation values associated with one request or operation.
final class ObservabilityContext {
  const ObservabilityContext({
    required this.requestId,
    required this.traceId,
    required this.spanId,
    required this.sampled,
    this.userId,
    this.workspaceId,
    this.route,
    this.method,
  });

  static const Object _zoneKey = #dartHttpObservabilityContext;

  static ObservabilityContext? get current => Zone.current[_zoneKey] as ObservabilityContext?;

  static R run<R>(ObservabilityContext context, R Function() fn) {
    return runZoned(fn, zoneValues: <Object?, Object?>{_zoneKey: context});
  }

  final String requestId;
  final String traceId;
  final String spanId;
  final bool sampled;
  final String? userId;
  final String? workspaceId;
  final String? route;
  final String? method;

  ObservabilityContext child({required String spanId}) {
    return ObservabilityContext(
      requestId: requestId,
      traceId: traceId,
      spanId: spanId,
      sampled: sampled,
      userId: userId,
      workspaceId: workspaceId,
      route: route,
      method: method,
    );
  }

  Map<String, Object?> toFields() => <String, Object?>{
    'requestId': requestId,
    'traceId': traceId,
    'spanId': spanId,
    if (userId != null) 'userId': userId,
    if (workspaceId != null) 'workspaceId': workspaceId,
    if (route != null) 'route': route,
    if (method != null) 'method': method,
  };
}

String requestIdFromHeaders(Map<String, String> headers) {
  final value = headers['x-request-id'] ?? headers['x-correlation-id'];
  return value == null || value.trim().isEmpty ? generateRequestId() : value.trim();
}

TraceParent? parseTraceParent(String? value) {
  final parts = value?.trim().split('-');
  if (parts == null ||
      parts.length != 4 ||
      parts[0] != '00' ||
      !_isLowerHex(parts[1], 32) ||
      !_isLowerHex(parts[2], 16) ||
      !_isLowerHex(parts[3], 2)) {
    return null;
  }
  return TraceParent(
    traceId: parts[1],
    parentSpanId: parts[2],
    sampled: (int.parse(parts[3], radix: 16) & 1) == 1,
  );
}

final class TraceParent {
  const TraceParent({required this.traceId, required this.parentSpanId, required this.sampled});

  final String traceId;
  final String parentSpanId;
  final bool sampled;
}

String generateRequestId() => _randomHex(16);
String generateTraceId() => _randomHex(32);
String generateSpanId() => _randomHex(16);

final Random _random = Random.secure();

String _randomHex(int length) {
  const chars = '0123456789abcdef';
  return List<String>.generate(length, (_) => chars[_random.nextInt(chars.length)]).join();
}

bool _isLowerHex(String value, int length) {
  if (value.length != length || value.split('').every((character) => character == '0')) {
    return false;
  }
  return RegExp(r'^[0-9a-f]+$').hasMatch(value);
}
