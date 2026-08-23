import 'package:dart_edge_core/dart_edge_core.dart';

import 'compiled_route.dart';
import 'json_schema_route_id.dart';

final class CompiledWebSocketRoute<TServices> {
  const CompiledWebSocketRoute({
    required this.routeId,
    required this.route,
    required this.guards,
    required this.options,
    required this.path,
    required this.patternSegments,
  });

  final String routeId;
  final WebSocketRouteDefinition<TServices> route;
  final List<Guard<TServices>> guards;
  final WebSocketOptions options;
  final String path;
  final List<RouteSegment> patternSegments;

  static CompiledWebSocketRoute<TServices>? tryParse<TServices>(
    RouteRegistration<TServices> registration,
    String routeId,
  ) {
    final route = registration.route;
    if (route is! WebSocketRouteDefinition<TServices>) {
      return null;
    }

    final options = route.options.normalized();
    final routePath = registration.httpPath;
    if (routePath == null) {
      throw StateError(
        'WebSocket route ${options.operationId} is missing path registration '
        'metadata.',
      );
    }
    final path = joinRoutePath(registration.prefix, routePath);
    return CompiledWebSocketRoute<TServices>(
      routeId: routeId,
      route: route,
      guards: registration.guards,
      options: _effectiveOptions(registration, options),
      path: path,
      patternSegments: parseRealtimePattern(path),
    );
  }

  Map<String, Object?> toNativeJson() => {
    'kind': 'webSocket',
    'routeId': routeId,
    'method': 'GET',
    'path': path,
    'operationId': options.operationId,
    'pathSegments': patternSegments.map((segment) => segment.toJson()).toList(),
    'paramsSchemaId': jsonSchemaRouteId(options.params),
    'querySchemaId': jsonSchemaRouteId(options.query),
    'headersSchemaId': null,
    'requestBody': null,
    'maxPendingMessages': options.maxPendingMessages,
    'maxPendingBytes': options.maxPendingBytes,
  };
}

WebSocketOptions _effectiveOptions<TServices>(
  RouteRegistration<TServices> registration,
  WebSocketOptions options,
) {
  return WebSocketOptions(
    operationId: options.operationId,
    summary: options.summary,
    tags: _mergeTags(registration.tags, options.tags),
    deprecated: options.deprecated,
    exposure: registration.exposure.restrict(options.exposure),
    params: options.params,
    paramsDecoder: options.paramsDecoder,
    query: options.query,
    queryDecoder: options.queryDecoder,
    maxPendingMessages: options.maxPendingMessages,
    maxPendingBytes: options.maxPendingBytes,
  );
}

List<RouteSegment> parseRealtimePattern(String path) {
  if (path == '/') {
    return const <RouteSegment>[];
  }

  return path
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .map((segment) {
        final parameterName = _parameterName(segment);
        if (parameterName != null) {
          return RouteSegment.parameter(parameterName);
        }
        return RouteSegment.literal(segment);
      })
      .toList(growable: false);
}

String? _parameterName(String segment) {
  if (segment.startsWith('<') && segment.endsWith('>')) {
    return segment.substring(1, segment.length - 1);
  }
  if (segment.startsWith(':') && segment.length > 1) {
    return segment.substring(1);
  }
  return null;
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
