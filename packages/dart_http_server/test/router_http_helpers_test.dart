import 'dart:io';

import 'package:dart_http_server/dart_http_server.dart';
import 'package:test/test.dart';

void main() {
  test('builds inline handler routes with stable defaults', () async {
    final app = DartHttp<TestServices>(services: TestServices.new);
    final api = app.router('/api');
    final healthGuard = HandlerGuard<TestServices>(
      debugName: 'requireAuth',
      handler: (_) => const GuardResult.allow(),
    );

    app.get('/health', guards: [healthGuard], handler: (ctx) => const {'status': 'ok'});
    api.put(
      '/users/<id>',
      options: RouteOptions(
        body: RequestBody.json(),
        success: ResponseSpec.json(status: HttpStatus.accepted),
      ),
      handler: (ctx) {
        final params = ctx.req.params<Map<String, String>>();
        final body = ctx.req.body<Map<String, Object?>>();
        return {'id': params['id'], 'body': body};
      },
    );
    api.delete(
      '/users/<id>',
      options: RouteOptions(success: ResponseSpec.text()),
      handler: (ctx) {
        final params = ctx.req.params<Map<String, String>>();
        return 'deleted:${params['id']}';
      },
    );

    final healthRegistration = app.routeRegistry.registrations[0];
    final updateRegistration = app.routeRegistry.registrations[1];
    final deleteRegistration = app.routeRegistry.registrations[2];

    final healthRoute = healthRegistration.route as HttpRouteDefinition<TestServices, dynamic>;
    final updateRoute = updateRegistration.route as HttpRouteDefinition<TestServices, dynamic>;
    final deleteRoute = deleteRegistration.route as HttpRouteDefinition<TestServices, dynamic>;

    final healthOptions = healthRoute.options;
    final updateOptions = updateRoute.options;
    final deleteOptions = deleteRoute.options;

    expect(healthRegistration.prefix, '');
    expect(updateRegistration.prefix, '/api');
    expect(deleteRegistration.prefix, '/api');

    expect(healthRegistration.httpMethod, HttpMethod.get);
    expect(healthRegistration.httpPath, '/health');
    expect(healthOptions.operationId, 'getHealth');
    expect(healthRegistration.guards, [same(healthGuard)]);
    expect(healthOptions.responses.success.contentType, 'application/json; charset=utf-8');

    expect(updateRegistration.httpMethod, HttpMethod.put);
    expect(updateRegistration.httpPath, '/users/<id>');
    expect(updateOptions.operationId, 'putApiUsersById');
    expect(updateOptions.body?.contentType, 'application/json; charset=utf-8');
    expect(updateOptions.responses.success.status, HttpStatus.accepted);

    expect(deleteRegistration.httpMethod, HttpMethod.delete);
    expect(deleteRegistration.httpPath, '/users/<id>');
    expect(deleteOptions.operationId, 'deleteApiUsersById');
    expect(deleteOptions.responses.success.contentType, 'text/plain; charset=utf-8');

    expect(healthRoute.handle(RequestContext<TestServices>(services: const TestServices())), {
      'status': 'ok',
    });
    expect(
      await updateRoute.handle(
        RequestContext<TestServices>(
          services: const TestServices(),
          req: RequestInput(params: const {'id': '42'}, body: const {'name': 'Ada'}),
        ),
      ),
      {
        'id': '42',
        'body': {'name': 'Ada'},
      },
    );
    expect(
      deleteRoute.handle(
        RequestContext<TestServices>(
          services: const TestServices(),
          req: RequestInput(params: const {'id': '42'}),
        ),
      ),
      'deleted:42',
    );

    expect(
      healthOptions.toString(),
      'RouteOptions(operationId: getHealth, success: 200 application/json; charset=utf-8)',
    );
    expect(
      healthRoute.toString(),
      'HandlerHttpRouteDefinition<TestServices, Map<String, String>>(operationId: getHealth)',
    );
    expect(
      updateRegistration.toString(),
      contains('RouteRegistration(PUT /api/users/<id>, operationId: putApiUsersById, '),
    );
    expect(healthRegistration.toString(), contains('guards: [requireAuth]'));
    expect(
      updateRegistration.toString(),
      contains(
        'route: HandlerHttpRouteDefinition<TestServices, Map<String, Object?>>'
        '(operationId: putApiUsersById)',
      ),
    );
  });

  test('builds inline handlers for every HTTP verb helper', () {
    final app = DartHttp<void>(services: () {});

    app.get('/get', handler: (_) => const {'method': 'get'});
    app.post('/post', handler: (_) => const {'method': 'post'});
    app.put('/put', handler: (_) => const {'method': 'put'});
    app.patch('/patch', handler: (_) => const {'method': 'patch'});
    app.delete('/delete', handler: (_) => const {'method': 'delete'});
    app.head('/head', handler: (_) => const {'method': 'head'});
    app.options('/options', handler: (_) => const {'method': 'options'});

    final methods = [
      for (final registration in app.routeRegistry.registrations) registration.httpMethod,
    ];

    expect(methods, [
      HttpMethod.get,
      HttpMethod.post,
      HttpMethod.put,
      HttpMethod.patch,
      HttpMethod.delete,
      HttpMethod.head,
      HttpMethod.options,
    ]);
  });

  test('builds inline websocket handlers with stable defaults', () async {
    final app = DartHttp<TestServices>(services: TestServices.new);

    app.websocket(
      '/ws/<roomId>',
      onConnect: (socket) async {
        await socket.sendJson({'roomId': socket.req.param('roomId')});
      },
    );

    final registration = app.routeRegistry.registrations.single;
    final route = registration.route as WebSocketRouteDefinition<TestServices>;
    final options = route.options;

    expect(registration.httpPath, '/ws/<roomId>');
    expect(options.operationId, 'webSocketWsByRoomId');
    expect(
      registration.toString(),
      contains('RouteRegistration(WS /ws/<roomId>, operationId: webSocketWsByRoomId'),
    );
  });

  test('mounts an independently built router under a base path', () {
    final app = DartHttp<TestServices>(services: TestServices.new);
    final feature = Router<TestServices>(tags: const ['feature']);
    final nested = feature.router('/v1', tags: const ['nested']);
    final appGuard = HandlerGuard<TestServices>(
      debugName: 'appGuard',
      handler: (_) => const GuardResult.allow(),
    );
    final featureGuard = HandlerGuard<TestServices>(
      debugName: 'featureGuard',
      handler: (_) => const GuardResult.allow(),
    );

    nested.get('/status', guards: [featureGuard], handler: (_) => const {'status': 'ok'});
    app.mountRouter('/api', feature, tags: const ['app'], guards: [appGuard]);

    final registration = app.routeRegistry.registrations.single;

    expect(registration.prefix, '/api/v1');
    expect(registration.httpMethod, HttpMethod.get);
    expect(registration.httpPath, '/status');
    expect(registration.tags, const ['app', 'feature', 'nested']);
    expect(registration.guards, [same(appGuard), same(featureGuard)]);
    expect(registration.toString(), contains('RouteRegistration(GET /api/v1/status'));
  });

  test('rejects mounting a router that already shares the registry', () {
    final app = DartHttp<TestServices>(services: TestServices.new);
    final child = app.router('/api');

    expect(() => app.mountRouter('/mounted', child), throwsA(isA<ArgumentError>()));
  });
}

final class TestServices {
  const TestServices();
}
