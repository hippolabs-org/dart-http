import 'dart:async';

import '../context/request_context.dart';
import 'route_options.dart';

/// Base class for an HTTP route handled in Dart and dispatched by the runtime.
abstract class HttpRouteDefinition<TServices, TSuccess> {
  RouteOptions get options;

  /// Handles one decoded request.
  FutureOr<TSuccess> handle(RequestContext<TServices> ctx);
}
