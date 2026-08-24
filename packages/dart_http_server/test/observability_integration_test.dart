import 'dart:io';

import 'package:dart_http_observability/dart_http_observability.dart';
import 'package:dart_http_server/dart_http_server.dart';
import 'package:test/test.dart';

void main() {
  test('installs request telemetry and returns request correlation', () async {
    final exporter = _RecordingExporter();
    final config = ObservabilityConfig(
      serviceName: 'integration-test',
      serviceVersion: '1.0.0',
      environment: 'test',
      logLevel: LogLevel.error,
      requestLoggingEnabled: false,
    );
    final observability = DartHttpObservability(
      config: config,
      tracer: Tracer(config: config, exporter: exporter),
    );
    final app = DartHttp<void>(
      services: () {},
      requestObservers: <HttpRequestObserver<void>>[observability.httpObserver<void>()],
    );
    app.get(
      '/health',
      handler: (context) {
        context.telemetry.addEvent('health.checked');
        return const <String, Object?>{'status': 'ok'};
      },
    );
    final server = await app.listen(port: 0);
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });

    final request = await client.getUrl(Uri.http('127.0.0.1:${server.port}', '/health'));
    request.headers.set('x-request-id', 'integration-request');
    final response = await request.close();
    await response.drain<void>();
    await Future<void>.delayed(Duration.zero);

    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.value('x-request-id'), 'integration-request');
    expect(exporter.spans.single.events.single.name, 'health.checked');
  });
}

final class _RecordingExporter implements TraceExporter {
  final List<ObservabilitySpan> spans = <ObservabilitySpan>[];

  @override
  Future<void> export(ObservabilitySpan span) async {
    spans.add(span);
  }
}
