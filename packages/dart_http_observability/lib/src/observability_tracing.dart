import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dart_http_core/dart_http_core.dart';

import 'observability_config.dart';
import 'observability_context.dart';
import 'structured_logger.dart';

final class ObservabilityEvent {
  ObservabilityEvent(this.name, this.attributes) : timestamp = DateTime.now().toUtc();

  final String name;
  final Map<String, Object?> attributes;
  final DateTime timestamp;
}

final class ObservabilitySpan {
  ObservabilitySpan({
    required this.name,
    required this.traceId,
    required this.spanId,
    required this.sampled,
    this.kind = ObservabilitySpanKind.internal,
    this.parentSpanId,
    Map<String, Object?> attributes = const {},
  }) : attributes = Map<String, Object?>.of(attributes),
       startedAt = DateTime.now().toUtc();

  final String name;
  final String traceId;
  final String spanId;
  final String? parentSpanId;
  final bool sampled;
  final ObservabilitySpanKind kind;
  final DateTime startedAt;
  final Map<String, Object?> attributes;
  final List<ObservabilityEvent> events = <ObservabilityEvent>[];
  DateTime? endedAt;
  Object? error;
  StackTrace? stackTrace;

  void addEvent(String name, {Map<String, Object?> attributes = const {}}) {
    events.add(ObservabilityEvent(name, Map<String, Object?>.of(attributes)));
  }

  void recordError(Object error, StackTrace stackTrace) {
    this.error = error;
    this.stackTrace = stackTrace;
  }

  void end() => endedAt ??= DateTime.now().toUtc();
}

enum ObservabilitySpanKind {
  internal(1),
  server(2);

  const ObservabilitySpanKind(this.otlpCode);

  final int otlpCode;
}

abstract interface class TraceExporter {
  Future<void> export(ObservabilitySpan span);
}

final class OtlpHttpTraceExporter implements TraceExporter {
  OtlpHttpTraceExporter(this.config, {HttpClient? client}) : _client = client ?? HttpClient();

  final ObservabilityConfig config;
  final HttpClient _client;

  @override
  Future<void> export(ObservabilitySpan span) async {
    final endpoint = config.otlpTracesEndpoint;
    if (endpoint == null || !span.sampled) return;
    try {
      final request = await _client.postUrl(Uri.parse(endpoint));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(_payload(span, config)));
      final response = await request.close();
      await response.drain<void>();
    } on Object {
      // Telemetry export must never fail a request.
    }
  }
}

final class Tracer {
  Tracer({required this.config, TraceExporter? exporter, Random? random})
    : exporter = exporter ?? OtlpHttpTraceExporter(config),
      _random = random ?? Random.secure();

  final ObservabilityConfig config;
  final TraceExporter exporter;
  final Random _random;

  ObservabilitySpan startSpan(
    String name, {
    String? traceId,
    String? parentSpanId,
    bool? sampled,
    ObservabilitySpanKind kind = ObservabilitySpanKind.internal,
    Map<String, Object?> attributes = const {},
  }) {
    return ObservabilitySpan(
      name: name,
      traceId: traceId ?? generateTraceId(),
      spanId: generateSpanId(),
      parentSpanId: parentSpanId,
      sampled: sampled ?? _random.nextDouble() < config.traceSampleRatio,
      kind: kind,
      attributes: attributes,
    );
  }

  void finish(ObservabilitySpan span) {
    span.end();
    unawaited(exporter.export(span));
  }
}

final class SpanRequestTelemetry extends RequestTelemetry {
  const SpanRequestTelemetry(this.span);

  final ObservabilitySpan span;

  @override
  void addEvent(String event, {Map<String, Object?> attributes = const {}}) {
    span.addEvent(event, attributes: attributes);
  }
}

/// Runs one domain operation as a child of the current request span.
Future<T> observeOperation<T>({
  required String name,
  required Tracer tracer,
  required JsonLogger logger,
  required FutureOr<T> Function(ObservabilityContext context) fn,
  ObservabilityContext? context,
  Map<String, Object?> attributes = const <String, Object?>{},
}) async {
  final parent = context ?? ObservabilityContext.current;
  if (parent == null) {
    throw StateError('observeOperation requires an active ObservabilityContext.');
  }
  final span = tracer.startSpan(
    name,
    traceId: parent.traceId,
    parentSpanId: parent.spanId,
    sampled: parent.sampled,
    attributes: attributes,
  );
  final child = parent.child(spanId: span.spanId);
  final startedAt = DateTime.now();
  return ObservabilityContext.run(child, () async {
    logger.info('operation.started', fields: <String, Object?>{'operation': name, ...attributes});
    try {
      final result = await fn(child);
      tracer.finish(span);
      logger.info(
        'operation.completed',
        fields: <String, Object?>{
          'operation': name,
          'durationMs': DateTime.now().difference(startedAt).inMicroseconds / 1000,
          ...attributes,
        },
      );
      return result;
    } catch (error, stackTrace) {
      span.recordError(error, stackTrace);
      tracer.finish(span);
      logger.error(
        'operation.failed',
        fields: <String, Object?>{
          'operation': name,
          'durationMs': DateTime.now().difference(startedAt).inMicroseconds / 1000,
          'errorName': error.runtimeType.toString(),
          'errorMessage': '$error',
          if (tracer.config.includeErrorStacks) 'stackTrace': '$stackTrace',
          ...attributes,
        },
      );
      rethrow;
    }
  });
}

Map<String, Object?> _payload(ObservabilitySpan span, ObservabilityConfig config) {
  final end = span.endedAt ?? DateTime.now().toUtc();
  final attributes = <String, Object?>{
    ...span.attributes,
    if (span.error != null) 'error.type': span.error.runtimeType.toString(),
    if (span.error != null) 'error.message': '${span.error}',
    if (config.includeErrorStacks && span.stackTrace != null)
      'error.stack': span.stackTrace.toString(),
  };
  return <String, Object?>{
    'resourceSpans': [
      {
        'resource': {
          'attributes': [
            _attribute('service.name', config.serviceName),
            _attribute('service.version', config.serviceVersion),
            _attribute('deployment.environment.name', config.environment),
          ],
        },
        'scopeSpans': [
          {
            'scope': {'name': 'dart_http_observability'},
            'spans': [
              {
                'traceId': span.traceId,
                'spanId': span.spanId,
                if (span.parentSpanId != null) 'parentSpanId': span.parentSpanId,
                'name': span.name,
                'kind': span.kind.otlpCode,
                'startTimeUnixNano': '${span.startedAt.microsecondsSinceEpoch * 1000}',
                'endTimeUnixNano': '${end.microsecondsSinceEpoch * 1000}',
                'attributes': [
                  for (final entry in attributes.entries) _attribute(entry.key, entry.value),
                ],
                'events': [
                  for (final event in span.events)
                    {
                      'name': event.name,
                      'timeUnixNano': '${event.timestamp.microsecondsSinceEpoch * 1000}',
                      'attributes': [
                        for (final entry in event.attributes.entries)
                          _attribute(entry.key, entry.value),
                      ],
                    },
                ],
                'status': {'code': span.error == null ? 1 : 2},
              },
            ],
          },
        ],
      },
    ],
  };
}

Map<String, Object?> _attribute(String key, Object? value) => <String, Object?>{
  'key': key,
  'value': switch (value) {
    final bool value => {'boolValue': value},
    final int value => {'intValue': '$value'},
    final double value => {'doubleValue': value},
    _ => {'stringValue': '$value'},
  },
};
