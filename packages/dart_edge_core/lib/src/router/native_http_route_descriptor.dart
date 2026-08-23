import '../http/http_method.dart';

/// Serializable native HTTP route metadata returned by native packages.
final class NativeHttpRouteDescriptor {
  const NativeHttpRouteDescriptor({
    required this.method,
    required this.path,
    required this.operationId,
    required this.acceptsJsonBody,
    this.pluginName,
  });

  /// HTTP method accepted by the native route.
  final HttpMethod method;

  /// Absolute route path exposed by the native package.
  final String path;

  /// Stable operation id for direct calls and OpenAPI output.
  final String operationId;

  /// Whether the route accepts a JSON request body.
  final bool acceptsJsonBody;

  /// Plugin or native module that contributed this route.
  final String? pluginName;

  factory NativeHttpRouteDescriptor.fromJson(Map<String, Object?> json) {
    return NativeHttpRouteDescriptor(
      method: _decodeMethod(json['method'] as String),
      path: json['path'] as String,
      operationId: json['operationId'] as String,
      acceptsJsonBody: json['acceptsJsonBody'] as bool? ?? false,
      pluginName: json['pluginName'] as String?,
    );
  }

  static List<NativeHttpRouteDescriptor> listFromJson(Iterable<Object?> json) {
    return json
        .cast<Map<String, Object?>>()
        .map(NativeHttpRouteDescriptor.fromJson)
        .toList(growable: false);
  }

  Map<String, Object?> toJson() {
    return {
      'method': method.name.toUpperCase(),
      'path': path,
      'operationId': operationId,
      'acceptsJsonBody': acceptsJsonBody,
      'pluginName': ?pluginName,
    };
  }

  @override
  String toString() {
    return 'NativeHttpRouteDescriptor(${method.name.toUpperCase()} $path, '
        'operationId: $operationId, jsonBody: $acceptsJsonBody'
        '${pluginName == null ? '' : ', plugin: $pluginName'})';
  }
}

/// Serializable native HTTP route manifest returned by native packages.
final class NativeHttpRouteManifest {
  NativeHttpRouteManifest({required Iterable<NativeHttpRouteDescriptor> routes})
    : routes = List<NativeHttpRouteDescriptor>.unmodifiable(routes);

  /// Native HTTP routes exposed by a native package.
  final List<NativeHttpRouteDescriptor> routes;

  factory NativeHttpRouteManifest.fromJson(Map<String, Object?> json) {
    return NativeHttpRouteManifest(
      routes: NativeHttpRouteDescriptor.listFromJson(
        json['routes'] as List<Object?>? ?? const <Object?>[],
      ),
    );
  }

  Map<String, Object?> toJson() {
    return {'routes': routes.map((route) => route.toJson()).toList()};
  }
}

HttpMethod _decodeMethod(String method) => switch (method.toUpperCase()) {
  'GET' => HttpMethod.get,
  'POST' => HttpMethod.post,
  'PUT' => HttpMethod.put,
  'PATCH' => HttpMethod.patch,
  'DELETE' => HttpMethod.delete,
  'HEAD' => HttpMethod.head,
  'OPTIONS' => HttpMethod.options,
  _ => throw ArgumentError.value(method, 'method', 'Unsupported HTTP method'),
};
