import 'package:dart_http_core/dart_http_core.dart';

import 'compiled_route.dart';
import 'json_schema_route_id.dart';

final class CompiledNativeHttpRoute implements CompiledOpenApiRoute {
  const CompiledNativeHttpRoute({
    required this.routeId,
    required this.mount,
    required this.method,
    required this.options,
    required this.path,
    required this.openApiPath,
    required this.patternSegments,
    required this.handlerPatternSegments,
  });

  final String routeId;
  final NativeHttpRouteMount mount;
  @override
  final HttpMethod method;
  @override
  final RouteOptions options;
  final String path;
  @override
  final String openApiPath;
  @override
  final List<RouteSegment> patternSegments;
  final List<RouteSegment>? handlerPatternSegments;

  static CompiledNativeHttpRoute? tryParse<TServices>(
    RouteRegistration<TServices> registration,
    String routeId,
  ) {
    final mount = registration.route;
    if (mount is! NativeHttpRouteMount) {
      return null;
    }
    final routePath = registration.httpPath;
    final method = registration.httpMethod;
    if (method == null || routePath == null) {
      throw StateError(
        'Native HTTP route ${mount.options.operationId} is missing method/path '
        'registration metadata.',
      );
    }

    final path = joinRoutePath(registration.prefix, routePath);
    final patternSegments = parseRoutePattern(path);
    final handlerPath = mount.handlerPath;
    return CompiledNativeHttpRoute(
      routeId: routeId,
      mount: mount,
      method: method,
      options: effectiveRouteOptions(registration, mount.options.normalized()),
      path: path,
      openApiPath: openApiPathForSegments(patternSegments),
      patternSegments: patternSegments,
      handlerPatternSegments: handlerPath == null ? null : parseRoutePattern(handlerPath),
    );
  }

  Map<String, Object?> toNativeJson() => {
    'kind': 'nativeHttp',
    'routeId': routeId,
    'method': method.wireName,
    'path': path,
    'operationId': options.operationId!,
    'pathSegments': patternSegments.map((segment) => segment.toJson()).toList(),
    if (handlerPatternSegments case final segments?)
      'handlerPathSegments': segments.map((segment) => segment.toJson()).toList(),
    'paramsSchemaId': jsonSchemaRouteId(options.params),
    'querySchemaId': jsonSchemaRouteId(options.query),
    'headersSchemaId': jsonSchemaRouteId(options.headers),
    'requestBody': switch (options.body) {
      null => null,
      final body => {'contentType': body.contentType, 'schemaId': jsonSchemaRouteId(body.schema)},
    },
    'nativeHandle': mount.nativeHandle,
    'nativeHandlerAddress': mount.nativeHandlerAddress,
    'nativeFreeResponseAddress': mount.nativeFreeResponseAddress,
  };
}
