import 'dart:async';

import 'web_transport_context.dart';
import 'web_transport_options.dart';

/// Base class for a WebTransport route surface.
abstract class WebTransportRouteDefinition<TServices> {
  WebTransportOptions get options;

  /// Called after the WebTransport session is accepted.
  FutureOr<void> onConnect(WebTransportContext<TServices> transport);
}
