import '../http/http_method.dart';
import '../websocket/web_socket_route_definition.dart';
import '../websocket/web_socket_route_mount.dart';
import '../webtransport/web_transport_route_definition.dart';
import '../webtransport/web_transport_route_mount.dart';
import 'guard.dart';
import 'http_route_definition.dart';
import 'http_route_mount.dart';
import 'native_http_route_mount.dart';
import 'route_exposure.dart';
import 'route_path.dart';

/// In-memory route registration table shared across router scopes.
final class RouteRegistry<TServices> {
  final List<RouteRegistration<TServices>> registrations = <RouteRegistration<TServices>>[];

  void registerHttp({
    required String prefix,
    required List<String> tags,
    required List<Guard<TServices>> guards,
    required RouteExposure exposure,
    required HttpRouteMount<TServices, dynamic> mount,
  }) {
    registrations.add(
      RouteRegistration(
        prefix: prefix,
        tags: tags,
        guards: guards,
        exposure: exposure,
        route: mount.route,
        httpMethod: mount.method,
        httpPath: mount.path,
      ),
    );
  }

  void registerWebSocket({
    required String prefix,
    required List<String> tags,
    required List<Guard<TServices>> guards,
    required RouteExposure exposure,
    required WebSocketRouteMount<TServices> mount,
  }) {
    registrations.add(
      RouteRegistration(
        prefix: prefix,
        tags: tags,
        guards: guards,
        exposure: exposure,
        route: mount.route,
        httpPath: mount.path,
      ),
    );
  }

  void registerWebTransport({
    required String prefix,
    required List<String> tags,
    required List<Guard<TServices>> guards,
    required RouteExposure exposure,
    required WebTransportRouteMount<TServices> mount,
  }) {
    registrations.add(
      RouteRegistration(
        prefix: prefix,
        tags: tags,
        guards: guards,
        exposure: exposure,
        route: mount.route,
        httpPath: mount.path,
      ),
    );
  }

  void registerNativeHttp({
    required String prefix,
    required List<String> tags,
    required List<Guard<TServices>> guards,
    required RouteExposure exposure,
    required NativeHttpRouteMount mount,
  }) {
    registrations.add(
      RouteRegistration(
        prefix: prefix,
        tags: tags,
        guards: guards,
        exposure: exposure,
        route: mount,
        httpMethod: mount.method,
        httpPath: mount.path,
      ),
    );
  }

  void registerMounted({
    required String prefix,
    required List<String> tags,
    required List<Guard<TServices>> guards,
    required RouteExposure exposure,
    required RouteRegistration<TServices> registration,
  }) {
    registrations.add(
      RouteRegistration(
        prefix: prefix,
        tags: tags,
        guards: guards,
        exposure: exposure,
        route: registration.route,
        httpMethod: registration.httpMethod,
        httpPath: registration.httpPath,
      ),
    );
  }
}

/// One registered route together with inherited router metadata.
final class RouteRegistration<TServices> {
  RouteRegistration({
    required this.prefix,
    required List<String> tags,
    required List<Guard<TServices>> guards,
    required this.exposure,
    required this.route,
    this.httpMethod,
    this.httpPath,
  }) : tags = List<String>.unmodifiable(tags),
       guards = List<Guard<TServices>>.unmodifiable(guards);

  final String prefix;
  final List<String> tags;
  final List<Guard<TServices>> guards;
  final RouteExposure exposure;
  final Object route;
  final HttpMethod? httpMethod;
  final String? httpPath;

  @override
  String toString() {
    switch (route) {
      case final HttpRouteDefinition<TServices, dynamic> route:
        final method = httpMethod;
        final path = httpPath;
        if (method == null || path == null) {
          return 'RouteRegistration(prefix: $prefix, tags: $tags, guards: $guards, route: $route)';
        }
        final fullPath = joinRoutePath(prefix, path);
        final options = route.options.normalized();
        final routeTags = _mergeTags(tags, options.tags);
        final parts = <String>[
          '${method.name.toUpperCase()} $fullPath',
          'operationId: ${options.operationId!}',
          if (routeTags.isNotEmpty) 'tags: $routeTags',
          if (guards.isNotEmpty) 'guards: $guards',
          if (exposure != RouteExposure.all) 'exposure: $exposure',
          'route: $route',
        ];
        return 'RouteRegistration(${parts.join(', ')})';
      case final WebSocketRouteDefinition<TServices> route:
        final path = httpPath;
        if (path == null) {
          return 'RouteRegistration(prefix: $prefix, tags: $tags, guards: $guards, route: $route)';
        }
        final fullPath = joinRoutePath(prefix, path);
        final options = route.options.normalized();
        final routeTags = _mergeTags(tags, options.tags);
        final parts = <String>[
          'WS $fullPath',
          'operationId: ${options.operationId}',
          if (routeTags.isNotEmpty) 'tags: $routeTags',
          if (guards.isNotEmpty) 'guards: $guards',
          if (exposure != RouteExposure.all) 'exposure: $exposure',
          'route: $route',
        ];
        return 'RouteRegistration(${parts.join(', ')})';
      case final WebTransportRouteDefinition<TServices> route:
        final path = httpPath;
        if (path == null) {
          return 'RouteRegistration(prefix: $prefix, tags: $tags, guards: $guards, route: $route)';
        }
        final fullPath = joinRoutePath(prefix, path);
        final options = route.options.normalized();
        final routeTags = _mergeTags(tags, options.tags);
        final parts = <String>[
          'WT $fullPath',
          'operationId: ${options.operationId}',
          if (routeTags.isNotEmpty) 'tags: $routeTags',
          if (guards.isNotEmpty) 'guards: $guards',
          if (exposure != RouteExposure.all) 'exposure: $exposure',
          'route: $route',
        ];
        return 'RouteRegistration(${parts.join(', ')})';
      default:
        return 'RouteRegistration(prefix: $prefix, tags: $tags, guards: $guards, route: $route)';
    }
  }
}

List<String> _mergeTags(Iterable<String> first, Iterable<String> second) {
  final merged = <String>[];
  final seen = <String>{};
  for (final tag in [...first, ...second]) {
    if (seen.add(tag)) {
      merged.add(tag);
    }
  }
  return merged;
}
