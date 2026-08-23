import 'package:dart_edge_core/dart_edge_core.dart';

import 'compiled_route.dart' show RouteSegment;
import 'compiled_web_socket_route.dart' show parseRealtimePattern;

final class CompiledWebTransportRoute<TServices> {
  const CompiledWebTransportRoute({
    required this.routeId,
    required this.route,
    required this.guards,
    required this.options,
    required this.path,
    required this.patternSegments,
  });

  final String routeId;
  final WebTransportRouteDefinition<TServices> route;
  final List<Guard<TServices>> guards;
  final WebTransportOptions options;
  final String path;
  final List<RouteSegment> patternSegments;

  static CompiledWebTransportRoute<TServices>? tryParse<TServices>(
    RouteRegistration<TServices> registration,
    String routeId,
  ) {
    final route = registration.route;
    if (route is! WebTransportRouteDefinition<TServices>) {
      return null;
    }

    final options = route.options.normalized();
    final routePath = registration.httpPath;
    if (routePath == null) {
      throw StateError(
        'WebTransport route ${options.operationId} is missing path registration '
        'metadata.',
      );
    }
    final path = joinRoutePath(registration.prefix, routePath);
    return CompiledWebTransportRoute<TServices>(
      routeId: routeId,
      route: route,
      guards: registration.guards,
      options: _effectiveOptions(registration, options),
      path: path,
      patternSegments: parseRealtimePattern(path),
    );
  }

  Map<String, Object?> toNativeJson() => {
    'kind': 'webTransport',
    'routeId': routeId,
    'method': 'GET',
    'path': path,
    'operationId': options.operationId,
    'pathSegments': patternSegments.map((segment) => segment.toJson()).toList(),
    'paramsSchemaId': null,
    'querySchemaId': null,
    'headersSchemaId': null,
    'requestBody': null,
    'maxPendingMessages': options.maxPendingMessages,
    'maxPendingBytes': options.maxPendingBytes,
  };
}

WebTransportOptions _effectiveOptions<TServices>(
  RouteRegistration<TServices> registration,
  WebTransportOptions options,
) {
  return WebTransportOptions(
    operationId: options.operationId,
    summary: options.summary,
    tags: _mergeTags(registration.tags, options.tags),
    deprecated: options.deprecated,
    exposure: registration.exposure.restrict(options.exposure),
    maxPendingMessages: options.maxPendingMessages,
    maxPendingBytes: options.maxPendingBytes,
  );
}

List<String> _mergeTags(Iterable<String> first, Iterable<String> second) {
  final merged = <String>[];
  final seen = <String>{};
  for (final tag in [...first, ...second]) {
    if (seen.add(tag)) {
      merged.add(tag);
    }
  }
  return List<String>.unmodifiable(merged);
}
