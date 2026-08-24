# dart_http_observability

Structured logging, Prometheus-compatible metrics, OTLP/HTTP tracing, request
correlation, and request instrumentation for Dart HTTP services.

```dart
final observability = DartHttpObservability(
  config: ObservabilityConfig.fromEnvironment(),
);
final app = DartHttp<AppServices>(
  services: AppServices.new,
  requestObservers: [observability.httpObserver<AppServices>()],
);

app.get('/health', handler: (ctx) {
  ctx.telemetry.addEvent('health.checked');
  return const {'status': 'ok'};
});
app.mountMetricsEndpoint(observability: observability);
```

The observer uses normalized route patterns for metric labels, propagates
W3C `traceparent`, returns an `x-request-id` response header, and makes the
correlation context available through `ObservabilityContext.current` and
`ctx.require<ObservabilityContext>()`.

Configure it with `SERVICE_NAME`, `SERVICE_VERSION`, `ENVIRONMENT`, `LOG_LEVEL`,
`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`, `OTEL_TRACES_SAMPLER_ARG`, and
`REQUEST_LOGGING_ENABLED`.
