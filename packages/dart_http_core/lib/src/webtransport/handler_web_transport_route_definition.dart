import 'dart:async';

import 'web_transport_context.dart';
import 'web_transport_options.dart';
import 'web_transport_route_definition.dart';

/// Signature for a closure-backed WebTransport route handler.
typedef WebTransportRouteHandler<TServices> = FutureOr<void> Function(
  WebTransportContext<TServices> transport,
);

/// Concrete [WebTransportRouteDefinition] backed by an inline handler.
final class HandlerWebTransportRouteDefinition<TServices>
    extends WebTransportRouteDefinition<TServices> {
  HandlerWebTransportRouteDefinition({required this._options, required this._handler});

  final WebTransportOptions _options;
  final WebTransportRouteHandler<TServices> _handler;

  @override
  WebTransportOptions get options => _options;

  @override
  FutureOr<void> onConnect(WebTransportContext<TServices> transport) => _handler(transport);

  @override
  String toString() {
    return 'HandlerWebTransportRouteDefinition<$TServices>('
        'operationId: ${_options.operationId})';
  }
}
