import 'package:dart_edge_core/dart_edge_core.dart';
import 'package:json_schema/json_schema.dart';

import 'compiled_route.dart';
import 'json_schema_route_id.dart';

/// Application-level OpenAPI metadata and document generation.
final class OpenApiDocument {
  OpenApiDocument({
    this.title = 'Dart Edge API',
    this.version = '1.0.0',
    this.summary,
    this.description,
    this.termsOfService,
    this.contact,
    this.license,
    List<OpenApiServer> servers = const <OpenApiServer>[],
    List<OpenApiTag> tags = const <OpenApiTag>[],
    this.externalDocs,
    Map<String, OpenApiSecurityScheme> securitySchemes = const <String, OpenApiSecurityScheme>{},
    List<OpenApiSecurityRequirement> security = const <OpenApiSecurityRequirement>[],
  }) : servers = List<OpenApiServer>.unmodifiable(servers.map((server) => server._immutableCopy())),
       tags = List<OpenApiTag>.unmodifiable(tags),
       securitySchemes = Map<String, OpenApiSecurityScheme>.unmodifiable(securitySchemes),
       security = List<OpenApiSecurityRequirement>.unmodifiable(security);

  /// API title shown in generated docs.
  final String title;

  /// API version shown in generated docs.
  final String version;

  /// Optional short summary of the API.
  final String? summary;

  /// Optional human-readable description for the API.
  final String? description;

  /// Optional URL for the API terms of service.
  final String? termsOfService;

  /// Optional contact information for the exposed API.
  final OpenApiContact? contact;

  /// Optional license information for the exposed API.
  final OpenApiLicense? license;

  /// Explicit server list included in the generated document.
  final List<OpenApiServer> servers;

  /// Declared tags and their documentation metadata.
  final List<OpenApiTag> tags;

  /// Optional external documentation for the API.
  final OpenApiExternalDocumentation? externalDocs;

  /// Named security schemes included in `components.securitySchemes`.
  final Map<String, OpenApiSecurityScheme> securitySchemes;

  /// Global security requirements applied to operations by default.
  final List<OpenApiSecurityRequirement> security;

  /// Builds an OpenAPI 3.1 document from compiled routes and schemas.
  Map<String, Object?> toJson({
    required Iterable<CompiledOpenApiRoute> routes,
    JsonSchemaRegistry? schemaRegistry,
  }) {
    final paths = <String, Map<String, Object?>>{};

    for (final route in routes) {
      final pathItem = paths.putIfAbsent(route.openApiPath, () => <String, Object?>{});
      pathItem[route.method.name] = _buildOperation(route, schemaRegistry);
    }

    final components = <String, Object?>{
      if (schemaRegistry case final registry? when registry.schemas.isNotEmpty)
        'schemas': {
          for (final schema in registry.schemas) ?schema.id: _openApiSchemaObject(schema.toJson()),
        },
      if (securitySchemes.isNotEmpty)
        'securitySchemes': {
          for (final entry in securitySchemes.entries) entry.key: entry.value.toJson(),
        },
    };

    return {
      'openapi': '3.1.0',
      'info': {
        'title': title,
        'version': version,
        'summary': ?summary,
        'description': ?description,
        'termsOfService': ?termsOfService,
        if (contact case final contact?) 'contact': contact.toJson(),
        if (license case final license?) 'license': license.toJson(),
      },
      if (servers.isNotEmpty)
        'servers': servers.map((server) => server.toJson()).toList(growable: false),
      'paths': paths,
      if (components.isNotEmpty) 'components': components,
      if (security.isNotEmpty)
        'security': security.map((requirement) => requirement.toJson()).toList(growable: false),
      if (tags.isNotEmpty) 'tags': tags.map((tag) => tag.toJson()).toList(growable: false),
      if (externalDocs case final externalDocs?) 'externalDocs': externalDocs.toJson(),
    };
  }
}

/// One OpenAPI server entry.
final class OpenApiServer {
  const OpenApiServer({
    required this.url,
    this.description,
    this.variables = const <String, OpenApiServerVariable>{},
  });

  final String url;
  final String? description;
  final Map<String, OpenApiServerVariable> variables;

  OpenApiServer _immutableCopy() => OpenApiServer(
    url: url,
    description: description,
    variables: Map<String, OpenApiServerVariable>.unmodifiable({
      for (final entry in variables.entries) entry.key: entry.value._immutableCopy(),
    }),
  );

  Map<String, Object?> toJson() => {
    'url': url,
    'description': ?description,
    if (variables.isNotEmpty)
      'variables': {for (final entry in variables.entries) entry.key: entry.value.toJson()},
  };
}

/// One variable interpolated into an OpenAPI server URL template.
final class OpenApiServerVariable {
  const OpenApiServerVariable({
    required this.defaultValue,
    this.description,
    this.enumValues = const <String>[],
  });

  final String defaultValue;
  final String? description;
  final List<String> enumValues;

  OpenApiServerVariable _immutableCopy() => OpenApiServerVariable(
    defaultValue: defaultValue,
    description: description,
    enumValues: List<String>.unmodifiable(enumValues),
  );

  Map<String, Object?> toJson() => {
    'default': defaultValue,
    'description': ?description,
    if (enumValues.isNotEmpty) 'enum': enumValues,
  };
}

/// Contact information for an OpenAPI document.
final class OpenApiContact {
  const OpenApiContact({this.name, this.url, this.email});

  final String? name;
  final String? url;
  final String? email;

  Map<String, Object?> toJson() => {'name': ?name, 'url': ?url, 'email': ?email};
}

/// License information for an OpenAPI document.
final class OpenApiLicense {
  const OpenApiLicense({required this.name, this.identifier, this.url})
    : assert(
        identifier == null || url == null,
        'OpenAPI license identifier and URL are mutually exclusive.',
      );

  final String name;
  final String? identifier;
  final String? url;

  Map<String, Object?> toJson() => {'name': name, 'identifier': ?identifier, 'url': ?url};
}

/// External documentation linked from an API or tag.
final class OpenApiExternalDocumentation {
  const OpenApiExternalDocumentation({required this.url, this.description});

  final String url;
  final String? description;

  Map<String, Object?> toJson() => {'url': url, 'description': ?description};
}

/// A declared OpenAPI tag with optional documentation metadata.
final class OpenApiTag {
  const OpenApiTag({required this.name, this.description, this.externalDocs});

  final String name;
  final String? description;
  final OpenApiExternalDocumentation? externalDocs;

  Map<String, Object?> toJson() => {
    'name': name,
    'description': ?description,
    if (externalDocs case final externalDocs?) 'externalDocs': externalDocs.toJson(),
  };
}

/// A named OpenAPI security scheme definition.
final class OpenApiSecurityScheme {
  /// Creates an HTTP authentication scheme such as `bearer` or `basic`.
  const OpenApiSecurityScheme.http({required this.scheme, this.bearerFormat, this.description})
    : type = 'http',
      name = null,
      location = null;

  /// Creates an API-key scheme carried by a header, query, or cookie value.
  const OpenApiSecurityScheme.apiKey({
    required this.name,
    required OpenApiApiKeyLocation in_,
    this.description,
  }) : type = 'apiKey',
       scheme = null,
       bearerFormat = null,
       location = in_;

  final String type;
  final String? scheme;
  final String? bearerFormat;
  final String? description;
  final String? name;
  final OpenApiApiKeyLocation? location;

  Map<String, Object?> toJson() => {
    'type': type,
    'scheme': ?scheme,
    'bearerFormat': ?bearerFormat,
    'description': ?description,
    'name': ?name,
    if (location case final location?) 'in': location.wireName,
  };
}

/// Supported locations for OpenAPI API-key authentication.
enum OpenApiApiKeyLocation {
  query('query'),
  header('header'),
  cookie('cookie');

  const OpenApiApiKeyLocation(this.wireName);

  final String wireName;
}

/// One global OpenAPI security requirement object.
///
/// Multiple entries in [schemes] are combined with AND. Multiple requirements
/// in [OpenApiDocument.security] are alternatives combined with OR.
final class OpenApiSecurityRequirement {
  OpenApiSecurityRequirement(Map<String, Iterable<String>> schemes)
    : schemes = Map<String, List<String>>.unmodifiable({
        for (final entry in schemes.entries) entry.key: List<String>.unmodifiable(entry.value),
      });

  /// Creates a requirement for one scheme with optional OAuth scopes.
  factory OpenApiSecurityRequirement.scheme(
    String name, {
    Iterable<String> scopes = const <String>[],
  }) {
    return OpenApiSecurityRequirement({name: scopes});
  }

  final Map<String, List<String>> schemes;

  Map<String, Object?> toJson() => <String, Object?>{
    for (final entry in schemes.entries) entry.key: entry.value,
  };
}

Map<String, Object?> _buildOperation(
  CompiledOpenApiRoute route,
  JsonSchemaRegistry? schemaRegistry,
) {
  final options = route.options;
  final parameters = <Map<String, Object?>>[
    ..._buildPathParameters(route, schemaRegistry),
    ..._buildObjectParameters(options.query, 'query', schemaRegistry, requiredByDefault: false),
    ..._buildObjectParameters(options.headers, 'header', schemaRegistry, requiredByDefault: false),
  ];

  return {
    'operationId': options.operationId!,
    'summary': ?options.summary,
    if (options.tags.isNotEmpty) 'tags': options.tags,
    if (options.deprecated) 'deprecated': true,
    if (parameters.isNotEmpty) 'parameters': parameters,
    if (options.body case final body?) 'requestBody': _buildRequestBody(body),
    'responses': _buildResponses(options.responses),
  };
}

List<Map<String, Object?>> _buildPathParameters(
  CompiledOpenApiRoute route,
  JsonSchemaRegistry? schemaRegistry,
) {
  final pathParameters = [
    for (final segment in route.patternSegments)
      if (segment.isParameter) segment.value,
  ];
  if (pathParameters.isEmpty) {
    return const <Map<String, Object?>>[];
  }

  final properties = _objectSchema(route.options.params, schemaRegistry)?.properties;
  return [
    for (final name in pathParameters)
      _buildParameter(
        name: name,
        in_: 'path',
        required: true,
        schema: properties?[name] ?? const JsonSchema.string(),
      ),
  ];
}

List<Map<String, Object?>> _buildObjectParameters(
  JsonSchema? objectSchema,
  String location,
  JsonSchemaRegistry? schemaRegistry, {
  required bool requiredByDefault,
}) {
  if (objectSchema == null) {
    return const <Map<String, Object?>>[];
  }

  final schema = _objectSchema(objectSchema, schemaRegistry);
  if (schema == null) {
    return const <Map<String, Object?>>[];
  }

  if (schema.properties.isEmpty) {
    return const <Map<String, Object?>>[];
  }

  final requiredFieldNames = schema.required.toSet();
  return [
    for (final entry in schema.properties.entries)
      _buildParameter(
        name: entry.key,
        in_: location,
        required: requiredByDefault || requiredFieldNames.contains(entry.key),
        schema: entry.value,
      ),
  ];
}

Map<String, Object?> _buildRequestBody(RequestBody body) {
  final schema = _contentSchema(body.contentType, schema: body.schema);
  return {
    'required': true,
    'content': {
      _contentTypeEssence(body.contentType): {'schema': ?schema},
    },
  };
}

Map<String, Object?> _buildResponses(ResponseSet responses) {
  final builtResponses = <String, Object?>{
    '${responses.success.status}': _buildResponse(
      responses.success,
      description: _statusDescription(responses.success.status),
    ),
  };

  for (final error in responses.errors) {
    builtResponses['${error.status}'] = _buildErrorResponse(error);
  }

  return builtResponses;
}

Map<String, Object?> _buildResponse(ResponseSpec spec, {required String description}) {
  final schema = _contentSchema(spec.contentType, schema: spec.schema);
  return {
    'description': description,
    if (schema != null)
      'content': {
        _contentTypeEssence(spec.contentType): {'schema': schema},
      },
  };
}

Map<String, Object?> _buildErrorResponse(ErrorResponse response) {
  return {
    'description': switch (response.code) {
      final code? => '${_statusDescription(response.status)} ($code)',
      null => _statusDescription(response.status),
    },
  };
}

Map<String, Object?> _buildParameter({
  required String name,
  required String in_,
  required bool required,
  required JsonSchema schema,
}) {
  return {
    'name': name,
    'in': in_,
    'required': required,
    'description': ?schema.description,
    'schema': _openApiSchemaObject(schema.toJson()),
  };
}

Map<String, Object?>? _contentSchema(String contentType, {required JsonSchema? schema}) {
  if (schema case final schema?) {
    return _openApiSchemaObject(schema.toJson());
  }

  return switch (_contentTypeEssence(contentType)) {
    'application/json' => <String, Object?>{},
    'text/plain' || 'text/html' => <String, Object?>{'type': 'string'},
    _ => null,
  };
}

JsonObjectSchema? _objectSchema(JsonSchema? schema, JsonSchemaRegistry? schemaRegistry) {
  return switch (schema) {
    final JsonObjectSchema schema => schema,
    final JsonReferenceSchema schema => switch (jsonSchemaRouteId(schema)) {
      final schemaId? => switch (schemaRegistry?.schemaFor(schemaId)) {
        final JsonObjectSchema schema => schema,
        _ => null,
      },
      _ => null,
    },
    _ => null,
  };
}

Map<String, Object?> _openApiSchemaObject(Object? value) {
  final normalized = _rewriteSchema(value);
  if (normalized is Map<String, Object?>) {
    return normalized;
  }
  if (normalized is Map) {
    return {for (final entry in normalized.entries) '${entry.key}': entry.value};
  }
  return const <String, Object?>{};
}

Object? _rewriteSchema(Object? value) {
  switch (value) {
    case List():
      return value.map(_rewriteSchema).toList(growable: false);
    case Map():
      final rewritten = <String, Object?>{};
      for (final entry in value.entries) {
        final key = '${entry.key}';
        if (key == r'$id') {
          continue;
        }
        if (key == r'$ref' && entry.value is String) {
          final ref = entry.value as String;
          rewritten[key] = _rewriteRef(ref);
          continue;
        }
        rewritten[key] = _rewriteSchema(entry.value);
      }
      return rewritten;
    default:
      return value;
  }
}

String _rewriteRef(String ref) {
  if (ref.startsWith('#') || (Uri.tryParse(ref)?.hasScheme ?? false)) {
    return ref;
  }
  return '#/components/schemas/$ref';
}

String _contentTypeEssence(String contentType) => contentType.split(';').first.trim().toLowerCase();

String _statusDescription(int status) => switch (status) {
  200 => 'OK',
  201 => 'Created',
  202 => 'Accepted',
  204 => 'No Content',
  400 => 'Bad Request',
  401 => 'Unauthorized',
  404 => 'Not Found',
  409 => 'Conflict',
  415 => 'Unsupported Media Type',
  422 => 'Unprocessable Entity',
  500 => 'Internal Server Error',
  _ => 'HTTP $status',
};
