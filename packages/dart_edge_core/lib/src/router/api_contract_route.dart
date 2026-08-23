import 'dart:async';

import '../context/request_context.dart';
import 'http_route_definition.dart';
import 'route_options.dart';

/// Metadata-only route definition for packages that publish API contracts.
final class ApiContractRoute<TServices> extends HttpRouteDefinition<TServices, Object?> {
  ApiContractRoute(this.options);

  @override
  final RouteOptions options;

  @override
  FutureOr<Object?> handle(RequestContext<TServices> ctx) {
    throw UnsupportedError('API contract routes are metadata-only.');
  }
}
