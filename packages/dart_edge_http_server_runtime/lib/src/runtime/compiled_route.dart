import 'package:dart_edge_core/dart_edge_core.dart';

import 'json_schema_route_id.dart';

abstract interface class CompiledOpenApiRoute {
  HttpMethod get method;
  RouteOptions get options;
  String get openApiPath;
  List<RouteSegment> get patternSegments;
}

final class CompiledRoute<TServices> implements CompiledOpenApiRoute {
  const CompiledRoute({
    required this.routeId,
    required this.route,
    required this.guards,
    required this.method,
    required this.options,
    required this.path,
    required this.openApiPath,
    required this.patternSegments,
  });

  final String routeId;
  final HttpRouteDefinition<TServices, dynamic> route;
  final List<Guard<TServices>> guards;
  @override
  final HttpMethod method;
  @override
  final RouteOptions options;
  final String path;
  @override
  final String openApiPath;
  @override
  final List<RouteSegment> patternSegments;

  static CompiledRoute<TServices>? tryParse<TServices>(
    RouteRegistration<TServices> registration,
    String routeId,
  ) {
    final route = registration.route;
    if (route is! HttpRouteDefinition<TServices, dynamic>) {
      return null;
    }

    final options = route.options.normalized();
    final method = registration.httpMethod;
    final routePath = registration.httpPath;
    if (method == null || routePath == null) {
      throw StateError(
        'HTTP route ${options.operationId} is missing method/path '
        'registration metadata.',
      );
    }
    final path = joinRoutePath(registration.prefix, routePath);
    final patternSegments = parseRoutePattern(path);
    return CompiledRoute<TServices>(
      routeId: routeId,
      route: route,
      guards: registration.guards,
      method: method,
      options: effectiveRouteOptions(registration, options),
      path: path,
      openApiPath: openApiPathForSegments(patternSegments),
      patternSegments: patternSegments,
    );
  }

  Map<String, Object?> toNativeJson() => {
    'kind': 'http',
    'routeId': routeId,
    'method': method.wireName,
    'path': path,
    'operationId': options.operationId!,
    'pathSegments': patternSegments.map((segment) => segment.toJson()).toList(),
    'paramsSchemaId': jsonSchemaRouteId(options.params),
    'querySchemaId': jsonSchemaRouteId(options.query),
    'headersSchemaId': jsonSchemaRouteId(options.headers),
    'requestBody': switch (options.body) {
      null => null,
      final body => {'contentType': body.contentType, 'schemaId': jsonSchemaRouteId(body.schema)},
    },
  };
}

RouteOptions effectiveRouteOptions<TServices>(
  RouteRegistration<TServices> registration,
  RouteOptions options,
) {
  return RouteOptions(
    operationId: options.operationId!,
    summary: options.summary,
    tags: _mergeTags(registration.tags, options.tags),
    deprecated: options.deprecated,
    exposure: registration.exposure.restrict(options.exposure),
    params: options.params,
    paramsDecoder: options.paramsDecoder,
    query: options.query,
    queryDecoder: options.queryDecoder,
    headers: options.headers,
    body: options.body,
    success: options.responses.success,
    errors: options.responses.errors,
  );
}

final class RouteSegment {
  const RouteSegment._({required this.value, required this.isParameter, this.isWildcard = false});

  final String value;
  final bool isParameter;
  final bool isWildcard;

  factory RouteSegment.literal(String value) {
    return RouteSegment._(value: value, isParameter: false);
  }

  factory RouteSegment.parameter(String value) {
    return RouteSegment._(value: value, isParameter: true);
  }

  factory RouteSegment.wildcard(String value) {
    return RouteSegment._(value: value, isParameter: true, isWildcard: true);
  }

  Map<String, Object?> toJson() => {
    'value': value,
    'isParameter': isParameter,
    if (isWildcard) 'isWildcard': true,
  };
}

List<RouteSegment> parseRoutePattern(String path) {
  if (path == '/') {
    return const <RouteSegment>[];
  }

  final segments = path
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .map((segment) {
        if (_wildcardName(segment) case final wildcardName?) {
          return RouteSegment.wildcard(wildcardName);
        }
        if (_parameterName(segment) case final parameterName?) {
          return RouteSegment.parameter(parameterName);
        }
        return RouteSegment.literal(segment);
      })
      .toList(growable: false);
  final wildcardIndex = segments.indexWhere((segment) => segment.isWildcard);
  if (wildcardIndex != -1 && wildcardIndex != segments.length - 1) {
    throw ArgumentError.value(
      path,
      'path',
      'Wildcard route segments must be the final path segment.',
    );
  }
  return segments;
}

String openApiPathForSegments(List<RouteSegment> segments) {
  if (segments.isEmpty) {
    return '/';
  }

  return '/${segments.map((segment) {
    if (segment.isParameter) {
      return '{${segment.value}}';
    }
    return segment.value;
  }).join('/')}';
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

String? _wildcardName(String segment) {
  if (segment.startsWith('<') && segment.endsWith('*>')) {
    return segment.substring(1, segment.length - 2);
  }
  if (segment.startsWith(':') && segment.endsWith('*') && segment.length > 2) {
    return segment.substring(1, segment.length - 1);
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
