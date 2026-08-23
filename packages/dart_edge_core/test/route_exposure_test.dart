import 'package:dart_edge_core/dart_edge_core.dart';
import 'package:json_schema/json_schema.dart';
import 'package:test/test.dart';

void main() {
  test('route realtime options default to all generated surfaces', () {
    final routeOptions = RouteOptions(
      operationId: 'getHealth',
      success: ResponseSpec.text(),
    ).normalized();
    final webSocketOptions = const WebSocketOptions(
      operationId: 'connectEvents',
      params: JsonSchema.ref('EventPath'),
      paramsDecoder: _decodeEventPath,
      query: JsonSchema.ref('EventQuery'),
      queryDecoder: _decodeEventQuery,
    ).normalized();
    final webTransportOptions = const WebTransportOptions(operationId: 'connectDatagrams')
        .normalized();

    expect(routeOptions.exposure, RouteExposure.all);
    expect(webSocketOptions.exposure, RouteExposure.all);
    expect(webSocketOptions.params, const JsonSchema.ref('EventPath'));
    expect(webSocketOptions.paramsDecoder, same(_decodeEventPath));
    expect(webSocketOptions.query, const JsonSchema.ref('EventQuery'));
    expect(webSocketOptions.queryDecoder, same(_decodeEventQuery));
    expect(webSocketOptions.maxPendingMessages, 256);
    expect(webSocketOptions.maxPendingBytes, 8 * 1024 * 1024);
    expect(webTransportOptions.exposure, RouteExposure.all);
    expect(webTransportOptions.maxPendingMessages, 256);
    expect(webTransportOptions.maxPendingBytes, 8 * 1024 * 1024);
  });

  test('realtime ingress queue ceilings must be positive', () {
    expect(
      () => const WebSocketOptions(operationId: 'socket', maxPendingMessages: 0).normalized(),
      throwsRangeError,
    );
    expect(
      () => const WebTransportOptions(operationId: 'transport', maxPendingBytes: 0).normalized(),
      throwsRangeError,
    );
  });

  test('router exposure is inherited restrictively', () {
    final app = Router<void>(exposure: RouteExposure.clientOnly);
    final internal = app.router('/internal', exposure: RouteExposure.openApiOnly);
    internal.get('/health', handler: (_) => const {'ok': true});

    final registration = app.routeRegistry.registrations.single;
    expect(registration.prefix, '/internal');
    expect(registration.exposure, RouteExposure.none);
  });

  test('mounted router exposure is inherited restrictively', () {
    final app = Router<void>(exposure: RouteExposure.openApiOnly);
    final feature = Router<void>(exposure: RouteExposure.clientOnly);
    feature.get('/health', handler: (_) => const {'ok': true});

    app.mountRouter('/feature', feature);

    final registration = app.routeRegistry.registrations.single;
    expect(registration.prefix, '/feature');
    expect(registration.exposure, RouteExposure.none);
  });
}

Object? _decodeEventPath(Map<String, String> values) => values;

Object? _decodeEventQuery(Map<String, String> values) => values;
