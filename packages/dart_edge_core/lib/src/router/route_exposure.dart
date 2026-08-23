/// Controls whether routes appear in generated surfaces.
final class RouteExposure {
  const RouteExposure({this.openApi = true, this.client = true});

  /// Include routes in every generated surface.
  static const all = RouteExposure();

  /// Exclude routes from every generated surface.
  static const none = RouteExposure(openApi: false, client: false);

  /// Alias for routes that are runtime-only implementation details.
  static const internal = RouteExposure(openApi: false, client: false);

  /// Include routes in OpenAPI output, but not generated clients.
  static const openApiOnly = RouteExposure(client: false);

  /// Include routes in generated clients, but not OpenAPI output.
  static const clientOnly = RouteExposure(openApi: false);

  /// Whether the route should appear in generated OpenAPI documents.
  final bool openApi;

  /// Whether the route should appear in generated client bindings.
  final bool client;

  /// Restricts this exposure by [other].
  ///
  /// Exposure is inherited through router scopes. Once a parent scope disables a
  /// surface, child routes cannot re-enable it accidentally.
  RouteExposure restrict(RouteExposure other) {
    return RouteExposure(openApi: openApi && other.openApi, client: client && other.client);
  }

  @override
  bool operator ==(Object other) {
    return other is RouteExposure && other.openApi == openApi && other.client == client;
  }

  @override
  int get hashCode => Object.hash(openApi, client);

  @override
  String toString() => 'RouteExposure(openApi: $openApi, client: $client)';
}
