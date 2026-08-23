import 'dart:convert';

import 'package:dart_edge_core/dart_edge_core.dart';
import 'package:json_schema/json_schema.dart';

import 'compiled_native_http_route.dart';
import 'compiled_route.dart';
import 'compiled_web_socket_route.dart';
import 'compiled_web_transport_route.dart';

final class CompiledRouteTable<TServices> {
  CompiledRouteTable._(
    this.routes,
    this.nativeRoutes,
    this.webSocketRoutes,
    this.webTransportRoutes,
  ) : routesById = {for (final route in routes) route.routeId: route},
      nativeRoutesById = {for (final route in nativeRoutes) route.routeId: route},
      webSocketRoutesById = {for (final route in webSocketRoutes) route.routeId: route},
      webTransportRoutesById = {for (final route in webTransportRoutes) route.routeId: route};

  final List<CompiledRoute<TServices>> routes;
  final Map<String, CompiledRoute<TServices>> routesById;
  final List<CompiledNativeHttpRoute> nativeRoutes;
  final Map<String, CompiledNativeHttpRoute> nativeRoutesById;
  final List<CompiledWebSocketRoute<TServices>> webSocketRoutes;
  final Map<String, CompiledWebSocketRoute<TServices>> webSocketRoutesById;
  final List<CompiledWebTransportRoute<TServices>> webTransportRoutes;
  final Map<String, CompiledWebTransportRoute<TServices>> webTransportRoutesById;

  String nativeManifestJson({JsonSchemaRegistry? schemaRegistry}) => jsonEncode({
    'routes': [
      ...routes.map((route) => route.toNativeJson()),
      ...nativeRoutes.map((route) => route.toNativeJson()),
      ...webSocketRoutes.map((route) => route.toNativeJson()),
      ...webTransportRoutes.map((route) => route.toNativeJson()),
    ],
    'schemas': schemaRegistry?.asMap() ?? const <String, Map<String, Object?>>{},
  });

  static CompiledRouteTable<TServices> fromRegistrations<TServices>(
    Iterable<RouteRegistration<TServices>> registrations,
  ) {
    final routes = <CompiledRoute<TServices>>[];
    final nativeRoutes = <CompiledNativeHttpRoute>[];
    final webSocketRoutes = <CompiledWebSocketRoute<TServices>>[];
    final webTransportRoutes = <CompiledWebTransportRoute<TServices>>[];
    var index = 0;

    for (final registration in registrations) {
      final routeId = 'route_$index';
      index += 1;
      final compiledRoute = CompiledRoute.tryParse(registration, routeId);
      if (compiledRoute != null) {
        routes.add(compiledRoute);
        continue;
      }

      final compiledNativeRoute = CompiledNativeHttpRoute.tryParse(registration, routeId);
      if (compiledNativeRoute != null) {
        nativeRoutes.add(compiledNativeRoute);
        continue;
      }

      final compiledWebSocketRoute = CompiledWebSocketRoute.tryParse(registration, routeId);
      if (compiledWebSocketRoute != null) {
        webSocketRoutes.add(compiledWebSocketRoute);
        continue;
      }

      final compiledWebTransportRoute = CompiledWebTransportRoute.tryParse(registration, routeId);
      if (compiledWebTransportRoute != null) {
        webTransportRoutes.add(compiledWebTransportRoute);
      }
    }

    return CompiledRouteTable<TServices>._(
      List.unmodifiable(routes),
      List.unmodifiable(nativeRoutes),
      List.unmodifiable(webSocketRoutes),
      List.unmodifiable(webTransportRoutes),
    );
  }
}
