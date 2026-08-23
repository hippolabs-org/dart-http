import 'web_transport_route_definition.dart';

/// Binds a WebTransport route definition to the endpoint where it is mounted.
final class WebTransportRouteMount<TServices> {
  const WebTransportRouteMount({required this.path, required this.route});

  /// Route path template, relative to the current router scope.
  final String path;

  /// Reusable WebTransport route implementation.
  final WebTransportRouteDefinition<TServices> route;
}
