import '../http/http_method.dart';
import 'http_route_definition.dart';

/// Binds an HTTP route definition to the endpoint where it is mounted.
final class HttpRouteMount<TServices, TSuccess> {
  const HttpRouteMount({required this.method, required this.path, required this.route});

  /// HTTP method accepted by the mounted route.
  final HttpMethod method;

  /// Route path pattern, for example `/users/<id>`.
  final String path;

  /// Reusable HTTP route implementation.
  final HttpRouteDefinition<TServices, TSuccess> route;

  @override
  String toString() {
    return 'HttpRouteMount<$TServices, $TSuccess>('
        'method: ${method.name.toUpperCase()}, path: $path, route: $route)';
  }
}
