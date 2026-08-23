import '../http/http_method.dart';
import 'route_options.dart';

/// Describes one typed API endpoint without binding it to an implementation.
final class ApiEndpoint {
  const ApiEndpoint({required this.method, required this.path, required this.options});

  /// HTTP method accepted by the endpoint.
  final HttpMethod method;

  /// Route path pattern, for example `/users/<id>`.
  final String path;

  /// Request, response, schema, and documentation metadata for the endpoint.
  final RouteOptions options;
}
