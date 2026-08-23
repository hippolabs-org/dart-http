import '../http/http_method.dart';
import '../websocket/handler_web_socket_route_definition.dart';
import '../websocket/web_socket_options.dart';
import '../websocket/web_socket_route_definition.dart';
import '../websocket/web_socket_route_mount.dart';
import '../webtransport/handler_web_transport_route_definition.dart';
import '../webtransport/web_transport_options.dart';
import '../webtransport/web_transport_route_definition.dart';
import '../webtransport/web_transport_route_mount.dart';
import 'guard.dart';
import 'handler_http_route_definition.dart';
import 'http_route_definition.dart';
import 'http_route_mount.dart';
import 'native_http_route_mount.dart';
import 'route_exposure.dart';
import 'route_options.dart';
import 'route_path.dart';
import 'route_registry.dart';

/// Route registration surface shared by apps and nested route groups.
class Router<TServices> {
  Router({
    this.prefix = '',
    List<String>? tags,
    List<Guard<TServices>>? guards,
    this.exposure = RouteExposure.all,
    RouteRegistry<TServices>? routeRegistry,
  }) : routeRegistry = routeRegistry ?? RouteRegistry<TServices>(),
       tags = List.unmodifiable(tags ?? const <String>[]),
       guards = List.unmodifiable(guards ?? <Guard<TServices>>[]);

  /// Prefix applied to every registered route.
  final String prefix;

  /// Shared route registry used by this router tree.
  final RouteRegistry<TServices> routeRegistry;

  /// Documentation tags associated with this router scope.
  final List<String> tags;

  /// Guard metadata associated with this router scope.
  final List<Guard<TServices>> guards;

  /// Generated surfaces associated with this router scope.
  final RouteExposure exposure;

  /// Creates a child router that shares the same registry under [childPrefix].
  Router<TServices> router(
    String childPrefix, {
    List<String>? tags,
    List<Guard<TServices>>? guards,
    RouteExposure exposure = RouteExposure.all,
  }) {
    return Router<TServices>(
      prefix: '$prefix$childPrefix',
      routeRegistry: routeRegistry,
      tags: [...this.tags, ...?tags],
      guards: [...this.guards, ...?guards],
      exposure: this.exposure.restrict(exposure),
    );
  }

  /// Mounts an independently built [router] under [basePath].
  ///
  /// The mounted router keeps the route objects it already registered. This
  /// applies this router's prefix, tags, and guards on top of the mounted
  /// router's existing registration metadata.
  void mountRouter(
    String basePath,
    Router<TServices> router, {
    List<String>? tags,
    List<Guard<TServices>>? guards,
    RouteExposure exposure = RouteExposure.all,
  }) {
    if (identical(routeRegistry, router.routeRegistry)) {
      throw ArgumentError.value(
        router,
        'router',
        'Cannot mount a router that already shares this route registry.',
      );
    }

    final mountPrefix = joinRoutePath(prefix, basePath);
    final mountedExposure = this.exposure.restrict(exposure);
    for (final registration in router.routeRegistry.registrations) {
      routeRegistry.registerMounted(
        prefix: joinRoutePath(mountPrefix, registration.prefix),
        tags: [...this.tags, ...?tags, ...registration.tags],
        guards: [...this.guards, ...?guards, ...registration.guards],
        exposure: mountedExposure.restrict(registration.exposure),
        registration: registration,
      );
    }
  }

  /// Mounts one explicit HTTP route mount.
  void mountHttpRoute<TSuccess>(
    HttpRouteMount<TServices, TSuccess> route, {
    List<Guard<TServices>>? guards,
  }) {
    _registerHttpRouteMount(route, guards: guards);
  }

  /// Mounts one explicit WebSocket route mount.
  void mountWebSocketRoute(WebSocketRouteMount<TServices> route, {List<Guard<TServices>>? guards}) {
    _registerWebSocketRouteMount(route, guards: guards);
  }

  /// Mounts one explicit WebTransport route mount.
  void mountWebTransportRoute(
    WebTransportRouteMount<TServices> route, {
    List<Guard<TServices>>? guards,
  }) {
    _registerWebTransportRouteMount(route, guards: guards);
  }

  /// Mounts one native HTTP route.
  void mountNativeHttpRoute(NativeHttpRouteMount route, {List<Guard<TServices>>? guards}) {
    routeRegistry.registerNativeHttp(
      prefix: prefix,
      tags: tags,
      guards: [...this.guards, ...?guards],
      exposure: exposure,
      mount: route,
    );
  }

  /// Registers an inline `GET` handler.
  void get<TSuccess>(
    String path, {
    RouteOptions options = const RouteOptions(),
    List<Guard<TServices>>? guards,
    required HttpRouteHandler<TServices, TSuccess> handler,
  }) {
    _registerHttpRoute(
      method: HttpMethod.get,
      path: path,
      options: options,
      guards: guards,
      handler: handler,
    );
  }

  /// Registers an explicit route class for `GET`.
  void routeGet<TSuccess>(
    String path,
    HttpRouteDefinition<TServices, TSuccess> route, {
    List<Guard<TServices>>? guards,
  }) {
    _registerHttpRouteDefinition(method: HttpMethod.get, path: path, route: route, guards: guards);
  }

  /// Registers an inline `POST` handler.
  void post<TSuccess>(
    String path, {
    RouteOptions options = const RouteOptions(),
    List<Guard<TServices>>? guards,
    required HttpRouteHandler<TServices, TSuccess> handler,
  }) {
    _registerHttpRoute(
      method: HttpMethod.post,
      path: path,
      options: options,
      guards: guards,
      handler: handler,
    );
  }

  /// Registers an explicit route class for `POST`.
  void routePost<TSuccess>(
    String path,
    HttpRouteDefinition<TServices, TSuccess> route, {
    List<Guard<TServices>>? guards,
  }) {
    _registerHttpRouteDefinition(method: HttpMethod.post, path: path, route: route, guards: guards);
  }

  /// Registers an inline `PUT` handler.
  void put<TSuccess>(
    String path, {
    RouteOptions options = const RouteOptions(),
    List<Guard<TServices>>? guards,
    required HttpRouteHandler<TServices, TSuccess> handler,
  }) {
    _registerHttpRoute(
      method: HttpMethod.put,
      path: path,
      options: options,
      guards: guards,
      handler: handler,
    );
  }

  /// Registers an explicit route class for `PUT`.
  void routePut<TSuccess>(
    String path,
    HttpRouteDefinition<TServices, TSuccess> route, {
    List<Guard<TServices>>? guards,
  }) {
    _registerHttpRouteDefinition(method: HttpMethod.put, path: path, route: route, guards: guards);
  }

  /// Registers an inline `PATCH` handler.
  void patch<TSuccess>(
    String path, {
    RouteOptions options = const RouteOptions(),
    List<Guard<TServices>>? guards,
    required HttpRouteHandler<TServices, TSuccess> handler,
  }) {
    _registerHttpRoute(
      method: HttpMethod.patch,
      path: path,
      options: options,
      guards: guards,
      handler: handler,
    );
  }

  /// Registers an explicit route class for `PATCH`.
  void routePatch<TSuccess>(
    String path,
    HttpRouteDefinition<TServices, TSuccess> route, {
    List<Guard<TServices>>? guards,
  }) {
    _registerHttpRouteDefinition(
      method: HttpMethod.patch,
      path: path,
      route: route,
      guards: guards,
    );
  }

  /// Registers an inline `DELETE` handler.
  void delete<TSuccess>(
    String path, {
    RouteOptions options = const RouteOptions(),
    List<Guard<TServices>>? guards,
    required HttpRouteHandler<TServices, TSuccess> handler,
  }) {
    _registerHttpRoute(
      method: HttpMethod.delete,
      path: path,
      options: options,
      guards: guards,
      handler: handler,
    );
  }

  /// Registers an explicit route class for `DELETE`.
  void routeDelete<TSuccess>(
    String path,
    HttpRouteDefinition<TServices, TSuccess> route, {
    List<Guard<TServices>>? guards,
  }) {
    _registerHttpRouteDefinition(
      method: HttpMethod.delete,
      path: path,
      route: route,
      guards: guards,
    );
  }

  /// Registers an inline `HEAD` handler.
  void head<TSuccess>(
    String path, {
    RouteOptions options = const RouteOptions(),
    List<Guard<TServices>>? guards,
    required HttpRouteHandler<TServices, TSuccess> handler,
  }) {
    _registerHttpRoute(
      method: HttpMethod.head,
      path: path,
      options: options,
      guards: guards,
      handler: handler,
    );
  }

  /// Registers an explicit route class for `HEAD`.
  void routeHead<TSuccess>(
    String path,
    HttpRouteDefinition<TServices, TSuccess> route, {
    List<Guard<TServices>>? guards,
  }) {
    _registerHttpRouteDefinition(method: HttpMethod.head, path: path, route: route, guards: guards);
  }

  /// Registers an inline `OPTIONS` handler.
  void options<TSuccess>(
    String path, {
    RouteOptions options = const RouteOptions(),
    List<Guard<TServices>>? guards,
    required HttpRouteHandler<TServices, TSuccess> handler,
  }) {
    _registerHttpRoute(
      method: HttpMethod.options,
      path: path,
      options: options,
      guards: guards,
      handler: handler,
    );
  }

  /// Registers an explicit route class for `OPTIONS`.
  void routeOptions<TSuccess>(
    String path,
    HttpRouteDefinition<TServices, TSuccess> route, {
    List<Guard<TServices>>? guards,
  }) {
    _registerHttpRouteDefinition(
      method: HttpMethod.options,
      path: path,
      route: route,
      guards: guards,
    );
  }

  /// Registers an inline WebSocket handler.
  void websocket(
    String path, {
    WebSocketOptions options = const WebSocketOptions(),
    List<Guard<TServices>>? guards,
    required WebSocketRouteHandler<TServices> onConnect,
  }) {
    mountWebSocketRoute(
      WebSocketRouteMount<TServices>(
        path: path,
        route: HandlerWebSocketRouteDefinition<TServices>(
          options: options.normalized(defaultOperationId: _defaultWebSocketOperationId(path: path)),
          handler: onConnect,
        ),
      ),
      guards: guards,
    );
  }

  /// Registers an explicit WebSocket route class.
  void routeWebSocket(
    String path,
    WebSocketRouteDefinition<TServices> route, {
    List<Guard<TServices>>? guards,
  }) {
    mountWebSocketRoute(
      WebSocketRouteMount<TServices>(path: path, route: route),
      guards: guards,
    );
  }

  /// Registers an inline WebTransport handler.
  void webtransport(
    String path, {
    WebTransportOptions options = const WebTransportOptions(),
    List<Guard<TServices>>? guards,
    required WebTransportRouteHandler<TServices> onConnect,
  }) {
    mountWebTransportRoute(
      WebTransportRouteMount<TServices>(
        path: path,
        route: HandlerWebTransportRouteDefinition<TServices>(
          options: options.normalized(
            defaultOperationId: _defaultWebTransportOperationId(path: path),
          ),
          handler: onConnect,
        ),
      ),
      guards: guards,
    );
  }

  /// Registers an explicit WebTransport route class.
  void routeWebTransport(
    String path,
    WebTransportRouteDefinition<TServices> route, {
    List<Guard<TServices>>? guards,
  }) {
    mountWebTransportRoute(
      WebTransportRouteMount<TServices>(path: path, route: route),
      guards: guards,
    );
  }

  void _registerHttpRoute<TSuccess>({
    required HttpMethod method,
    required String path,
    required RouteOptions options,
    List<Guard<TServices>>? guards,
    required HttpRouteHandler<TServices, TSuccess> handler,
  }) {
    _registerHttpRouteDefinition(
      method: method,
      path: path,
      guards: guards,
      route: HandlerHttpRouteDefinition<TServices, TSuccess>(
        options: options.normalized(
          defaultOperationId: _defaultOperationId(method: method, path: path),
        ),
        handler: handler,
      ),
    );
  }

  void _registerHttpRouteDefinition<TSuccess>({
    required HttpMethod method,
    required String path,
    required HttpRouteDefinition<TServices, TSuccess> route,
    List<Guard<TServices>>? guards,
  }) {
    mountHttpRoute(
      HttpRouteMount<TServices, TSuccess>(method: method, path: path, route: route),
      guards: guards,
    );
  }

  void _registerHttpRouteMount<TSuccess>(
    HttpRouteMount<TServices, TSuccess> mount, {
    List<Guard<TServices>>? guards,
  }) {
    routeRegistry.registerHttp(
      prefix: prefix,
      tags: tags,
      guards: [...this.guards, ...?guards],
      exposure: exposure,
      mount: mount,
    );
  }

  void _registerWebSocketRouteMount(
    WebSocketRouteMount<TServices> mount, {
    List<Guard<TServices>>? guards,
  }) {
    routeRegistry.registerWebSocket(
      prefix: prefix,
      tags: tags,
      guards: [...this.guards, ...?guards],
      exposure: exposure,
      mount: mount,
    );
  }

  void _registerWebTransportRouteMount(
    WebTransportRouteMount<TServices> mount, {
    List<Guard<TServices>>? guards,
  }) {
    routeRegistry.registerWebTransport(
      prefix: prefix,
      tags: tags,
      guards: [...this.guards, ...?guards],
      exposure: exposure,
      mount: mount,
    );
  }

  String _defaultOperationId({required HttpMethod method, required String path}) {
    final words = _defaultPathWords(path);
    if (words.isEmpty) {
      return '${method.name}Root';
    }

    return method.name + words.map(_capitalize).join();
  }

  String _defaultWebSocketOperationId({required String path}) {
    final words = _defaultPathWords(path);
    if (words.isEmpty) {
      return 'webSocketRoot';
    }

    return 'webSocket${words.map(_capitalize).join()}';
  }

  String _defaultWebTransportOperationId({required String path}) {
    final words = _defaultPathWords(path);
    if (words.isEmpty) {
      return 'webTransportRoot';
    }

    return 'webTransport${words.map(_capitalize).join()}';
  }

  List<String> _defaultPathWords(String path) {
    final fullPath = joinRoutePath(prefix, path);
    if (fullPath == '/') {
      return const <String>[];
    }

    final words = <String>[];
    for (final segment in fullPath.split('/').where((segment) => segment.isNotEmpty)) {
      if (segment.startsWith('<') && segment.endsWith('>')) {
        final parameter = segment.substring(1, segment.length - 1);
        words.add('by');
        words.addAll(_segmentWords(parameter));
        continue;
      }

      if (segment.startsWith(':') && segment.length > 1) {
        final parameter = segment.substring(1);
        words.add('by');
        words.addAll(_segmentWords(parameter));
        continue;
      }

      words.addAll(_segmentWords(segment));
    }

    if (words.isEmpty) {
      return const <String>[];
    }

    return words;
  }

  Iterable<String> _segmentWords(String segment) {
    final normalized = segment
        .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (match) => '${match[1]} ${match[2]}')
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), ' ');
    return normalized
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .map((word) => word.toLowerCase());
  }

  String _capitalize(String word) {
    if (word.isEmpty) {
      return word;
    }

    return '${word[0].toUpperCase()}${word.substring(1)}';
  }
}
