import 'dart:async';

import 'package:dart_http_core/dart_http_core.dart';

import 'observability_config.dart';
import 'observability_context.dart';
import 'observability_metrics.dart';
import 'observability_tracing.dart';
import 'structured_logger.dart';

/// Shared observability components for one Dart HTTP service.
final class DartHttpObservability {
  DartHttpObservability({
    required this.config,
    JsonLogger? logger,
    MetricsRegistry? metrics,
    Tracer? tracer,
  }) : logger = logger ?? StdoutJsonLogger(config),
       metrics = metrics ?? MetricsRegistry(),
       tracer = tracer ?? Tracer(config: config) {
    httpMetrics = StandardHttpMetrics(this.metrics);
  }

  final ObservabilityConfig config;
  final JsonLogger logger;
  final MetricsRegistry metrics;
  final Tracer tracer;
  late final StandardHttpMetrics httpMetrics;

  HttpRequestObserver<TServices> httpObserver<TServices>() =>
      ObservabilityHttpRequestObserver<TServices>(this);
}

/// Records structured logs, metrics, trace spans, and request correlation.
final class ObservabilityHttpRequestObserver<TServices> implements HttpRequestObserver<TServices> {
  const ObservabilityHttpRequestObserver(this.observability);

  final DartHttpObservability observability;

  @override
  Future<HttpRequestObservationResult> observe({
    required RequestContext<TServices> context,
    required HttpRequestObservation request,
    required Future<HttpRequestObservationResult> Function() next,
  }) {
    final method = request.method.wireName;
    final route = request.route;
    final traceParent = parseTraceParent(context.req.header('traceparent'));
    final span = observability.tracer.startSpan(
      'HTTP $method $route',
      traceId: traceParent?.traceId,
      parentSpanId: traceParent?.parentSpanId,
      sampled: traceParent?.sampled,
      kind: ObservabilitySpanKind.server,
      attributes: <String, Object?>{
        'http.request.method': method,
        'http.route': route,
        'http.operation_id': request.operationId,
      },
    );
    final requestContext = ObservabilityContext(
      requestId: requestIdFromHeaders(context.req.headersMap),
      traceId: span.traceId,
      spanId: span.spanId,
      sampled: span.sampled,
      route: route,
      method: method,
    );
    context
      ..put<ObservabilityContext>(requestContext)
      ..installTelemetry(SpanRequestTelemetry(span));
    context.res.header('x-request-id', requestContext.requestId);

    return ObservabilityContext.run(requestContext, () async {
      final startedAt = DateTime.now();
      final activeLabels = <String, String>{'method': method, 'route': route};
      observability.httpMetrics.activeRequests.inc(labels: activeLabels);
      if (observability.config.requestLoggingEnabled) {
        observability.logger.info('http.request.started');
      }

      try {
        final result = await next();
        final duration = DateTime.now().difference(startedAt);
        final labels = <String, String>{...activeLabels, 'status': '${result.statusCode}'};
        observability.httpMetrics.requests.inc(labels: labels);
        observability.httpMetrics.duration.observe(
          duration.inMicroseconds / Duration.microsecondsPerSecond,
          labels: labels,
        );
        if (result.responseBodySize case final size?) {
          observability.httpMetrics.responseBodySize.observe(size.toDouble(), labels: labels);
        }
        span.attributes['http.response.status_code'] = result.statusCode;
        observability.tracer.finish(span);
        if (observability.config.requestLoggingEnabled) {
          observability.logger.info(
            'http.request.completed',
            fields: <String, Object?>{
              'statusCode': result.statusCode,
              'durationMs': duration.inMicroseconds / 1000,
            },
          );
        }
        return result;
      } catch (error, stackTrace) {
        final duration = DateTime.now().difference(startedAt);
        observability.httpMetrics.errors.inc(
          labels: <String, String>{...activeLabels, 'errorName': error.runtimeType.toString()},
        );
        observability.httpMetrics.duration.observe(
          duration.inMicroseconds / Duration.microsecondsPerSecond,
          labels: <String, String>{...activeLabels, 'status': '500'},
        );
        span
          ..attributes['http.response.status_code'] = 500
          ..recordError(error, stackTrace);
        observability.tracer.finish(span);
        observability.logger.error(
          'http.request.failed',
          fields: <String, Object?>{
            'statusCode': 500,
            'durationMs': duration.inMicroseconds / 1000,
            'errorName': error.runtimeType.toString(),
            'errorMessage': '$error',
            if (observability.config.includeErrorStacks) 'stackTrace': '$stackTrace',
          },
        );
        rethrow;
      } finally {
        observability.httpMetrics.activeRequests.dec(labels: activeLabels);
      }
    });
  }
}

extension DartHttpObservabilityMetricsEndpoint<TServices> on Router<TServices> {
  void mountMetricsEndpoint({
    required DartHttpObservability observability,
    String path = '/metrics',
  }) {
    get<RawResponse>(
      path,
      options: const RouteOptions(operationId: 'metrics', success: ResponseSpec.text()),
      handler: (_) => RawResponse.encoded(
        status: 200,
        contentType: 'text/plain; version=0.0.4; charset=utf-8',
        body: observability.metrics.scrape(),
      ),
    );
  }
}
