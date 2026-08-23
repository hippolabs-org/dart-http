import 'dart:async';

import 'web_socket_context.dart';
import 'web_socket_options.dart';
import 'web_socket_route_definition.dart';

/// Signature for a closure-backed WebSocket route handler.
typedef WebSocketRouteHandler<TServices> = FutureOr<void> Function(
  WebSocketContext<TServices> socket,
);

/// Concrete [WebSocketRouteDefinition] backed by an inline handler.
final class HandlerWebSocketRouteDefinition<TServices> extends WebSocketRouteDefinition<TServices> {
  HandlerWebSocketRouteDefinition({required this._options, required this._handler});

  final WebSocketOptions _options;
  final WebSocketRouteHandler<TServices> _handler;

  @override
  WebSocketOptions get options => _options;

  @override
  FutureOr<void> onConnect(WebSocketContext<TServices> socket) => _handler(socket);

  @override
  String toString() {
    return 'HandlerWebSocketRouteDefinition<$TServices>('
        'operationId: ${_options.operationId})';
  }
}
