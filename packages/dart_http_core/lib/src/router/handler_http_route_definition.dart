import 'dart:async';

import '../context/request_context.dart';
import 'http_route_definition.dart';
import 'route_options.dart';

/// Signature for a closure-backed HTTP route handler.
typedef HttpRouteHandler<TServices, TSuccess> = FutureOr<TSuccess> Function(
  RequestContext<TServices> ctx,
);

/// Concrete [HttpRouteDefinition] backed by an inline [HttpRouteHandler].
final class HandlerHttpRouteDefinition<TServices, TSuccess>
    extends HttpRouteDefinition<TServices, TSuccess> {
  HandlerHttpRouteDefinition({required this._options, required this._handler});

  final RouteOptions _options;
  final HttpRouteHandler<TServices, TSuccess> _handler;

  @override
  RouteOptions get options => _options;

  @override
  FutureOr<TSuccess> handle(RequestContext<TServices> ctx) => _handler(ctx);

  @override
  String toString() {
    return 'HandlerHttpRouteDefinition<$TServices, $TSuccess>('
        'operationId: ${_options.operationId!})';
  }
}
