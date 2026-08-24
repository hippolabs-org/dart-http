import 'package:dart_http_core/dart_http_core.dart';
import 'package:dart_http_observability/dart_http_observability.dart';
import 'package:test/test.dart';

void main() {
  test('correlates requests and records handler telemetry events', () async {
    final exporter = _RecordingExporter();
    final logger = _RecordingLogger();
    final config = ObservabilityConfig(
      serviceName: 'test-service',
      serviceVersion: '1.0.0',
      environment: 'test',
      logLevel: LogLevel.debug,
    );
    final observability = DartHttpObservability(
      config: config,
      logger: logger,
      tracer: Tracer(config: config, exporter: exporter),
    );
    final observer = observability.httpObserver<void>();
    final context = RequestContext<void>(
      services: null,
      req: RequestInput(
        headersMap: const <String, String>{
          'x-request-id': 'request-42',
          'traceparent': '00-0123456789abcdef0123456789abcdef-0123456789abcdef-01',
        },
      ),
    );

    final result = await observer.observe(
      context: context,
      request: const HttpRequestObservation(
        method: HttpMethod.get,
        route: '/users/<id>',
        operationId: 'getUser',
        successStatusCode: 200,
      ),
      next: () async {
        expect(ObservabilityContext.current?.requestId, 'request-42');
        context.telemetry.addEvent('user.loaded', attributes: const {'cached': true});
        await observeOperation<void>(
          name: 'user.lookup',
          tracer: observability.tracer,
          logger: logger,
          fn: (operationContext) {
            expect(operationContext.traceId, '0123456789abcdef0123456789abcdef');
            expect(operationContext.spanId, isNot(context.require<ObservabilityContext>().spanId));
          },
        );
        return const HttpRequestObservationResult(statusCode: 200, responseBodySize: 12);
      },
    );
    await Future<void>.delayed(Duration.zero);

    expect(result.statusCode, 200);
    expect(context.require<ObservabilityContext>().traceId, '0123456789abcdef0123456789abcdef');
    expect(context.require<ObservabilityContext>().sampled, isTrue);
    expect(context.res.headers.single.name, 'x-request-id');
    expect(context.res.headers.single.value, 'request-42');
    expect(exporter.spans, hasLength(2));
    final requestSpan = exporter.spans.singleWhere(
      (span) => span.kind == ObservabilitySpanKind.server,
    );
    expect(requestSpan.events.single.name, 'user.loaded');
    expect(logger.events.map((event) => event.$2), [
      'http.request.started',
      'operation.started',
      'operation.completed',
      'http.request.completed',
    ]);
    expect(observability.metrics.scrape(), contains('http_server_requests_total'));
    expect(observability.metrics.scrape(), contains('route="/users/<id>"'));
  });

  test('rejects malformed traceparent values', () {
    expect(parseTraceParent('00-not-a-trace-id-0123456789abcdef-01'), isNull);
    expect(parseTraceParent('00-00000000000000000000000000000000-0123456789abcdef-01'), isNull);
  });
}

final class _RecordingExporter implements TraceExporter {
  final List<ObservabilitySpan> spans = <ObservabilitySpan>[];

  @override
  Future<void> export(ObservabilitySpan span) async {
    spans.add(span);
  }
}

final class _RecordingLogger extends JsonLogger {
  final List<(LogLevel, String, Map<String, Object?>)> events = [];

  @override
  void log(
    LogLevel level,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) {
    events.add((level, message, fields));
  }
}
