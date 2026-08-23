import 'dart:async';

import 'web_socket_context.dart';
import 'web_socket_options.dart';

/// Base class for a WebSocket route surface.
abstract class WebSocketRouteDefinition<TServices> {
  WebSocketOptions get options;

  /// Called when the socket is connected.
  FutureOr<void> onConnect(WebSocketContext<TServices> socket);
}
