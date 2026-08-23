import 'dart:convert';
import 'dart:io';

import 'package:code_builder/code_builder.dart';
import 'package:dart_http_core/dart_http_core.dart';
import 'package:dart_style/dart_style.dart';
import 'package:json_schema/json_schema.dart';

import '../json_schema_route_id.dart';

/// Build-time description of one generated client library.
final class DartHttpClientLibrarySpec {
  const DartHttpClientLibrarySpec({
    required this.className,
    required this.operations,
    this.webSockets = const <DartHttpClientWebSocketOperation>[],
    this.webTransports = const <DartHttpClientWebTransportOperation>[],
    this.schemas = const <JsonSchema>[],
    this.schemaTypes = const <String, String>{},
    this.externalSchemaIds = const <String>{},
    this.additionalImports = const <String>[],
  });

  final String className;
  final List<DartHttpClientOperation> operations;
  final List<DartHttpClientWebSocketOperation> webSockets;
  final List<DartHttpClientWebTransportOperation> webTransports;
  final List<JsonSchema> schemas;
  final Map<String, String> schemaTypes;
  final Set<String> externalSchemaIds;
  final List<String> additionalImports;

  factory DartHttpClientLibrarySpec.fromRouter({
    required String className,
    required Router<dynamic> router,
    List<JsonSchema> schemas = const <JsonSchema>[],
    Map<String, String> schemaTypes = const <String, String>{},
    Set<String> externalSchemaIds = const <String>{},
    List<String> additionalImports = const <String>[],
    DartHttpClientGenerationOptions options = const DartHttpClientGenerationOptions(),
  }) {
    final operations = <DartHttpClientOperation>[];
    final webSockets = <DartHttpClientWebSocketOperation>[];
    final webTransports = <DartHttpClientWebTransportOperation>[];
    final discoveredSchemas = _ClientSchemaCollector(schemas);

    for (final registration in router.routeRegistry.registrations) {
      final path = registration.httpPath;
      if (path == null) {
        continue;
      }

      final fullPath = joinRoutePath(registration.prefix, path);
      if (options.ignoresPath(fullPath)) {
        continue;
      }

      switch (registration.route) {
        case final HttpRouteDefinition<dynamic, dynamic> route:
          final method = registration.httpMethod;
          if (method == null) {
            continue;
          }
          final routeOptions = _effectiveRouteOptions(registration, route.options.normalized());
          if (!routeOptions.exposure.client ||
              options.ignoresOperation(routeOptions.operationId!)) {
            continue;
          }
          discoveredSchemas.addRouteOptions(routeOptions);
          operations.add(
            _operationFromOptions(
              method: method,
              path: fullPath,
              options: routeOptions,
              schemaTypes: schemaTypes,
              methodName:
                  _prefixedMethodName(registration.prefix, routeOptions.operationId!) ??
                  _pathPrefixedMethodName(
                    fullPath,
                    routeOptions.operationId!,
                    options.methodNamePathPrefixes,
                  ),
            ),
          );
        case final NativeHttpRouteMount route:
          final routeOptions = _effectiveRouteOptions(registration, route.options.normalized());
          if (!routeOptions.exposure.client ||
              options.ignoresOperation(routeOptions.operationId!)) {
            continue;
          }
          discoveredSchemas.addRouteOptions(routeOptions);
          operations.add(
            _operationFromOptions(
              method: route.method,
              path: fullPath,
              options: routeOptions,
              schemaTypes: schemaTypes,
              methodName:
                  _prefixedMethodName(registration.prefix, routeOptions.operationId!) ??
                  _pathPrefixedMethodName(
                    fullPath,
                    routeOptions.operationId!,
                    options.methodNamePathPrefixes,
                  ),
            ),
          );
        case final WebSocketRouteDefinition<dynamic> route:
          final webSocketOptions = _effectiveWebSocketOptions(
            registration,
            route.options.normalized(),
          );
          if (!webSocketOptions.exposure.client ||
              options.ignoresOperation(webSocketOptions.operationId!)) {
            continue;
          }
          discoveredSchemas.addWebSocketOptions(webSocketOptions);
          webSockets.add(
            _webSocketOperationFromOptions(
              path: fullPath,
              options: webSocketOptions,
              schemaTypes: schemaTypes,
              methodName:
                  _prefixedMethodName(registration.prefix, webSocketOptions.operationId!) ??
                  _pathPrefixedMethodName(
                    fullPath,
                    webSocketOptions.operationId!,
                    options.methodNamePathPrefixes,
                  ),
            ),
          );
        case final WebTransportRouteDefinition<dynamic> route:
          final webTransportOptions = _effectiveWebTransportOptions(
            registration,
            route.options.normalized(),
          );
          if (!webTransportOptions.exposure.client ||
              options.ignoresOperation(webTransportOptions.operationId!)) {
            continue;
          }
          webTransports.add(
            DartHttpClientWebTransportOperation(
              path: fullPath,
              operationId: webTransportOptions.operationId!,
              methodName:
                  _prefixedMethodName(registration.prefix, webTransportOptions.operationId!) ??
                  _pathPrefixedMethodName(
                    fullPath,
                    webTransportOptions.operationId!,
                    options.methodNamePathPrefixes,
                  ),
            ),
          );
      }
    }

    return DartHttpClientLibrarySpec(
      className: className,
      operations: operations,
      webSockets: webSockets,
      webTransports: webTransports,
      schemas: discoveredSchemas.schemas,
      schemaTypes: schemaTypes,
      externalSchemaIds: externalSchemaIds,
      additionalImports: additionalImports,
    );
  }
}

/// Client-generation filters applied after route exposure metadata.
final class DartHttpClientGenerationOptions {
  const DartHttpClientGenerationOptions({
    this.ignorePaths = const <String>{},
    this.ignoreOperations = const <String>{},
    this.methodNamePathPrefixes = const <String>{'/auth'},
  });

  /// Full public route template prefixes to skip after router prefixes are applied.
  ///
  /// A value matches the exact route path and any descendant path. For example,
  /// `/auth/admin` skips `/auth/admin` and `/auth/admin/users`, but not
  /// `/auth/administrator`.
  final Set<String> ignorePaths;

  /// Operation id prefixes to skip.
  final Set<String> ignoreOperations;

  /// Full route path prefixes that should namespace generated method names.
  ///
  /// This is for package-owned route groups that register absolute paths rather
  /// than a [RouteRegistration.prefix], such as Dart HTTP Auth's `/auth/...`
  /// routes.
  final Set<String> methodNamePathPrefixes;

  bool ignoresPath(String path) {
    return ignorePaths.any((ignored) => _matchesPathPrefix(path, ignored));
  }

  bool ignoresOperation(String operationId) {
    return ignoreOperations.any(operationId.startsWith);
  }
}

/// Writes generated Dart client files into a directory.
final class DartHttpClientFileEmitter {
  const DartHttpClientFileEmitter({
    this.generator = const DartHttpClientGenerator(),
    this.formatterOptions = const DartHttpClientFormatterOptions(),
  });

  final DartHttpClientGenerator generator;
  final DartHttpClientFormatterOptions formatterOptions;

  Future<void> emit(
    DartHttpClientLibrarySpec spec, {
    required Directory output,
    String libraryFile = 'client.g.dart',
    String bindingsFile = 'client.bindings.g.dart',
    String modelsFile = 'client.models.g.dart',
  }) async {
    await output.create(recursive: true);
    await File('${output.path}/$libraryFile').writeAsString(
      generator.generateLibrary(
        spec,
        bindingsPart: bindingsFile,
        modelsPart: modelsFile,
        formatterOptions: formatterOptions,
      ),
    );
    await File('${output.path}/$bindingsFile').writeAsString(
      generator.generateBindingsPart(
        spec,
        libraryFile: libraryFile,
        formatterOptions: formatterOptions,
      ),
    );
    await File('${output.path}/$modelsFile').writeAsString(
      generator.generateModelsPart(
        spec,
        libraryFile: libraryFile,
        formatterOptions: formatterOptions,
      ),
    );
  }
}

final class DartHttpClientFormatterOptions {
  const DartHttpClientFormatterOptions({this.pageWidth, this.trailingCommas});

  final int? pageWidth;
  final TrailingCommas? trailingCommas;

  DartFormatter createFormatter() {
    return DartFormatter(
      languageVersion: DartFormatter.latestLanguageVersion,
      pageWidth: pageWidth,
      trailingCommas: trailingCommas,
    );
  }
}

/// Build-time description of one generated client method.
final class DartHttpClientOperation {
  const DartHttpClientOperation({
    required this.method,
    required this.path,
    required this.options,
    required this.successType,
    this.methodName,
    this.paramsType,
    this.queryType,
    this.headersType,
    this.bodyType,
  });

  final HttpMethod method;
  final String path;
  final RouteOptions options;
  final String successType;
  final String? methodName;
  final String? paramsType;
  final String? queryType;
  final String? headersType;
  final String? bodyType;

  String get resolvedMethodName => methodName ?? _lowerCamel(options.operationId!);
}

/// Build-time description of one generated WebSocket client method.
final class DartHttpClientWebSocketOperation {
  const DartHttpClientWebSocketOperation({
    required this.path,
    required this.operationId,
    this.methodName,
    this.params,
    this.paramsType,
    this.query,
    this.queryType,
    this.headersType,
  });

  final String path;
  final String operationId;
  final String? methodName;
  final JsonSchema? params;
  final String? paramsType;
  final JsonSchema? query;
  final String? queryType;
  final String? headersType;

  String get resolvedMethodName => methodName ?? _lowerCamel(operationId);
}

/// Build-time description of one generated WebTransport client method.
final class DartHttpClientWebTransportOperation {
  const DartHttpClientWebTransportOperation({
    required this.path,
    required this.operationId,
    this.methodName,
    this.paramsType,
    this.queryType,
    this.headersType,
  });

  final String path;
  final String operationId;
  final String? methodName;
  final String? paramsType;
  final String? queryType;
  final String? headersType;

  String get resolvedMethodName => methodName ?? _lowerCamel(operationId);
}

/// Emits Dart source for an HTTP client backed by normalized route options.
final class DartHttpClientGenerator {
  const DartHttpClientGenerator();

  String generate(
    DartHttpClientLibrarySpec spec, {
    DartHttpClientFormatterOptions formatterOptions = const DartHttpClientFormatterOptions(),
  }) {
    final library = Library((builder) {
      builder
        ..comments.add('GENERATED CODE - DO NOT MODIFY BY HAND.')
        ..directives.add(Directive.import('package:dart_http_core/dart_http_core.dart'))
        ..directives.add(Directive.import('package:json_schema/json_schema.dart'));
      if (_needsTypedDataImport(spec)) {
        builder.directives.add(Directive.import('dart:typed_data'));
      }
      builder.body.addAll([..._modelSpecs(spec), ...buildSpecs(spec)]);

      for (final import in spec.additionalImports) {
        builder.directives.add(Directive.import(import));
      }
    });

    return _format(library, formatterOptions: formatterOptions);
  }

  String generateLibrary(
    DartHttpClientLibrarySpec spec, {
    String bindingsPart = 'client.bindings.g.dart',
    String modelsPart = 'client.models.g.dart',
    DartHttpClientFormatterOptions formatterOptions = const DartHttpClientFormatterOptions(),
  }) {
    final library = Library((builder) {
      builder
        ..comments.add('GENERATED CODE - DO NOT MODIFY BY HAND.')
        ..directives.add(Directive.import('package:dart_http_core/dart_http_core.dart'))
        ..directives.add(Directive.import('package:json_schema/json_schema.dart'));
      if (_needsTypedDataImport(spec)) {
        builder.directives.add(Directive.import('dart:typed_data'));
      }

      for (final import in spec.additionalImports) {
        builder.directives.add(Directive.import(import));
      }

      builder.directives
        ..add(Directive.part(modelsPart))
        ..add(Directive.part(bindingsPart));
    });

    return _format(library, formatterOptions: formatterOptions);
  }

  String generateBindingsPart(
    DartHttpClientLibrarySpec spec, {
    String libraryFile = 'client.g.dart',
    DartHttpClientFormatterOptions formatterOptions = const DartHttpClientFormatterOptions(),
  }) {
    final library = Library((builder) {
      builder
        ..comments.add('GENERATED CODE - DO NOT MODIFY BY HAND.')
        ..directives.add(Directive.partOf(libraryFile))
        ..body.addAll(buildSpecs(spec));
    });

    return _format(library, formatterOptions: formatterOptions);
  }

  String generateModelsPart(
    DartHttpClientLibrarySpec spec, {
    String libraryFile = 'client.g.dart',
    DartHttpClientFormatterOptions formatterOptions = const DartHttpClientFormatterOptions(),
  }) {
    final library = Library((builder) {
      builder
        ..comments.add('GENERATED CODE - DO NOT MODIFY BY HAND.')
        ..directives.add(Directive.partOf(libraryFile))
        ..body.addAll(_modelSpecs(spec));
    });

    return _format(library, formatterOptions: formatterOptions);
  }

  List<Spec> buildSpecs(DartHttpClientLibrarySpec spec) {
    return <Spec>[
      ...spec.operations.map(_httpOperationClass),
      ...spec.webSockets.map(_webSocketOperationClass),
      ...spec.webTransports.map(_webTransportOperationClass),
      _clientClass(spec),
    ];
  }

  List<Spec> _modelSpecs(DartHttpClientLibrarySpec spec) {
    final generatedTypeIds = _generatedModelTypeIds(spec);
    final multipartBodySchemaIds = _multipartBodySchemaIds(spec);
    final classes = <Class>[
      for (final schema in spec.schemas)
        if (schema is JsonObjectSchema &&
            schema.id != null &&
            !spec.externalSchemaIds.contains(schema.id) &&
            !spec.schemaTypes.containsKey(schema.id) &&
            generatedTypeIds.contains(_schemaTypeFromId(schema.id!, spec.schemaTypes)))
          _modelClass(
            _schemaTypeFromId(schema.id!, spec.schemaTypes)!,
            schema,
            spec.schemaTypes,
            source: multipartBodySchemaIds.contains(schema.id)
                ? _ClientModelSource.multipart
                : _ClientModelSource.json,
          ),
    ];
    if (classes.isEmpty) {
      return const <Spec>[];
    }
    return classes;
  }

  Set<String> _generatedModelTypeIds(DartHttpClientLibrarySpec spec) {
    final schemasByType = <String, JsonObjectSchema>{
      for (final schema in spec.schemas)
        if (schema is JsonObjectSchema &&
            schema.id != null &&
            !spec.externalSchemaIds.contains(schema.id) &&
            !spec.schemaTypes.containsKey(schema.id))
          _schemaTypeFromId(schema.id!, spec.schemaTypes)!: schema,
    };
    final generated = <String>{};
    final pending = <String>[];

    void addType(String? type) {
      if (type == null || _isRawTransportType(type)) {
        return;
      }
      if (!schemasByType.containsKey(type) || !generated.add(type)) {
        return;
      }
      pending.add(type);
    }

    for (final operation in spec.operations) {
      addType(operation.successType);
      addType(operation.paramsType);
      addType(operation.queryType);
      addType(operation.headersType);
      addType(operation.bodyType);
    }
    for (final operation in spec.webSockets) {
      addType(operation.paramsType);
      addType(operation.queryType);
      addType(operation.headersType);
    }
    for (final operation in spec.webTransports) {
      addType(operation.paramsType);
      addType(operation.queryType);
      addType(operation.headersType);
    }

    while (pending.isNotEmpty) {
      final schema = schemasByType[pending.removeLast()]!;
      for (final property in schema.properties.values) {
        addType(
          _clientModelType(
            property,
            nullable: false,
            schemaTypes: spec.schemaTypes,
            source: _ClientModelSource.json,
          ),
        );
      }
    }

    return generated;
  }

  Class _modelClass(
    String name,
    JsonObjectSchema schema,
    Map<String, String> schemaTypes, {
    required _ClientModelSource source,
  }) {
    return Class((builder) {
      builder
        ..modifier = ClassModifier.final$
        ..name = name
        ..implements.addAll(source == _ClientModelSource.json ? [refer('JsonEncodable')] : [])
        ..constructors.add(_modelConstructor(schema, schemaTypes, source))
        ..constructors.addAll(
          source == _ClientModelSource.json
              ? [_modelDecodeFactory(name), _modelFromJsonFactory(name, schema, schemaTypes)]
              : [],
        )
        ..fields.addAll(_modelFields(schema, schemaTypes, source))
        ..methods.add(
          source == _ClientModelSource.json
              ? _modelToJsonMethod(schema, schemaTypes)
              : _modelToMultipartFormDataMethod(schema, schemaTypes),
        );
    });
  }

  Constructor _modelConstructor(
    JsonObjectSchema schema,
    Map<String, String> schemaTypes,
    _ClientModelSource source,
  ) {
    return Constructor((builder) {
      builder
        ..constant = true
        ..optionalParameters.addAll([
          for (final field in _modelFieldSpecs(schema, schemaTypes, source))
            _namedParameter(field.name, required: field.required, toThis: true),
        ]);
    });
  }

  Constructor _modelFromJsonFactory(
    String name,
    JsonObjectSchema schema,
    Map<String, String> schemaTypes,
  ) {
    final fields = _modelFieldSpecs(schema, schemaTypes, _ClientModelSource.json);
    final assignments = fields.map((field) => '${field.name}: ${_decodeField(field)},').join('\n');
    return Constructor((builder) {
      builder
        ..factory = true
        ..name = 'fromJson'
        ..requiredParameters.add(
          Parameter((parameter) {
            parameter
              ..name = 'json'
              ..type = refer('Map<String, Object?>');
          }),
        )
        ..body = Code('''
return $name(
$assignments
);
''');
    });
  }

  Constructor _modelDecodeFactory(String name) {
    return Constructor((builder) {
      builder
        ..factory = true
        ..name = 'decode'
        ..requiredParameters.add(
          Parameter((parameter) {
            parameter
              ..name = 'value'
              ..type = refer('Object?');
          }),
        )
        ..body = Code('return $name.fromJson(readJsonObject(value));');
    });
  }

  Iterable<Field> _modelFields(
    JsonObjectSchema schema,
    Map<String, String> schemaTypes,
    _ClientModelSource source,
  ) {
    return [
      for (final field in _modelFieldSpecs(schema, schemaTypes, source))
        Field((builder) {
          builder
            ..modifier = FieldModifier.final$
            ..type = refer(field.type)
            ..name = field.name;
        }),
    ];
  }

  Method _modelToJsonMethod(JsonObjectSchema schema, Map<String, String> schemaTypes) {
    final entries = _modelFieldSpecs(
      schema,
      schemaTypes,
      _ClientModelSource.json,
    ).map((field) => "'${field.wireName}': ${_encodeField(field)},").join('\n');
    return Method((builder) {
      builder
        ..annotations.add(refer('override'))
        ..returns = refer('Map<String, Object?>')
        ..name = 'toJson'
        ..body = Code('''
return <String, Object?>{
$entries
};
''');
    });
  }

  Method _modelToMultipartFormDataMethod(JsonObjectSchema schema, Map<String, String> schemaTypes) {
    final fields = _modelFieldSpecs(schema, schemaTypes, _ClientModelSource.multipart);
    final textFields = fields
        .where((field) => !_isMultipartBinaryField(field.schema))
        .map(_multipartTextFieldExpression)
        .join('\n');
    final files = fields
        .where((field) => _isMultipartBinaryField(field.schema))
        .map(_multipartFileExpression)
        .join('\n');
    return Method((builder) {
      builder
        ..returns = refer('MultipartFormData')
        ..name = 'toMultipartFormData'
        ..body = Code('''
return MultipartFormData(
  fields: <MultipartFormField>[
$textFields
  ],
  files: <MultipartFile>[
$files
  ],
);
''');
    });
  }

  List<_ClientModelFieldSpec> _modelFieldSpecs(
    JsonObjectSchema schema,
    Map<String, String> schemaTypes,
    _ClientModelSource source,
  ) {
    return [
      for (final entry in schema.properties.entries)
        _ClientModelFieldSpec(
          wireName: entry.key,
          name: _lowerCamel(entry.key),
          schema: entry.value,
          required: schema.required.contains(entry.key),
          type: _clientModelType(
            entry.value,
            nullable: !schema.required.contains(entry.key),
            schemaTypes: schemaTypes,
            source: source,
          ),
          schemaTypes: schemaTypes,
        ),
    ];
  }

  String _decodeField(_ClientModelFieldSpec field) {
    final nullable = !field.required || field.schema.nullable;
    final access = nullable ? "json['${field.wireName}']" : "json['${field.wireName}']!";
    final decoded = _decodeSchemaValue(field.schema, access, field.schemaTypes);
    if (!nullable) {
      return decoded;
    }
    return "$access == null ? null : $decoded";
  }

  String _encodeField(_ClientModelFieldSpec field) {
    return _encodeSchemaValue(
      field.schema,
      field.name,
      nullable: !field.required || field.schema.nullable,
      schemaTypes: field.schemaTypes,
    );
  }

  Class _clientClass(DartHttpClientLibrarySpec spec) {
    return Class((builder) {
      builder
        ..modifier = ClassModifier.final$
        ..name = spec.className
        ..extend = refer('DartHttpClientBase')
        ..constructors.add(_clientConstructor())
        ..methods.addAll([
          ...spec.operations.map(_httpOperationGetter),
          ...spec.webSockets.map(_webSocketOperationGetter),
          ...spec.webTransports.map(_webTransportOperationGetter),
        ]);
    });
  }

  Class _httpOperationClass(DartHttpClientOperation operation) {
    return Class((builder) {
      builder
        ..modifier = ClassModifier.final$
        ..name = _operationClassName(operation.resolvedMethodName)
        ..constructors.add(
          Constructor(
            (builder) => builder
              ..constant = true
              ..requiredParameters.add(_thisParameter('_client')),
          ),
        )
        ..fields.add(_clientField())
        ..methods.addAll([
          _operationInfoGetter(
            operationId: operation.options.operationId!,
            kind: 'http',
            path: operation.path,
            method: operation.method,
          ),
          _operationMethod(operation, name: 'call'),
          _operationStartMethod(operation),
          if (_isBinaryOperation(operation))
            _binaryStreamOperationMethod(operation, name: 'stream'),
        ]);
    });
  }

  Class _webSocketOperationClass(DartHttpClientWebSocketOperation operation) {
    return Class((builder) {
      builder
        ..modifier = ClassModifier.final$
        ..name = _operationClassName(operation.resolvedMethodName)
        ..constructors.add(
          Constructor(
            (builder) => builder
              ..constant = true
              ..requiredParameters.add(_thisParameter('_client')),
          ),
        )
        ..fields.add(_clientField())
        ..methods.addAll([
          _operationInfoGetter(
            operationId: operation.operationId,
            kind: 'webSocket',
            path: operation.path,
          ),
          _webSocketMethod(operation, name: 'connect'),
        ]);
    });
  }

  Class _webTransportOperationClass(DartHttpClientWebTransportOperation operation) {
    return Class((builder) {
      builder
        ..modifier = ClassModifier.final$
        ..name = _operationClassName(operation.resolvedMethodName)
        ..constructors.add(
          Constructor(
            (builder) => builder
              ..constant = true
              ..requiredParameters.add(_thisParameter('_client')),
          ),
        )
        ..fields.add(_clientField())
        ..methods.addAll([
          _operationInfoGetter(
            operationId: operation.operationId,
            kind: 'webTransport',
            path: operation.path,
          ),
          _webTransportMethod(operation, name: 'connect'),
        ]);
    });
  }

  Field _clientField() => Field(
    (builder) => builder
      ..modifier = FieldModifier.final$
      ..type = refer('DartHttpClientBase')
      ..name = '_client',
  );

  Parameter _thisParameter(String name) => Parameter(
    (builder) => builder
      ..name = name
      ..toThis = true,
  );

  Method _operationInfoGetter({
    required String operationId,
    required String kind,
    required String path,
    HttpMethod? method,
  }) {
    return Method(
      (builder) => builder
        ..type = MethodType.getter
        ..returns = refer('DartHttpClientOperationInfo')
        ..name = 'info'
        ..body = refer('DartHttpClientOperationInfo')
            .constInstance([], {
              'operationId': literalString(operationId),
              'kind': refer('DartHttpClientOperationKind').property(kind),
              'pathTemplate': literalString(path),
              if (method != null) 'method': refer('HttpMethod').property(method.name),
            })
            .returned
            .statement,
    );
  }

  Method _httpOperationGetter(DartHttpClientOperation operation) =>
      _operationGetter(operation.resolvedMethodName);

  Method _webSocketOperationGetter(DartHttpClientWebSocketOperation operation) =>
      _operationGetter(operation.resolvedMethodName);

  Method _webTransportOperationGetter(DartHttpClientWebTransportOperation operation) =>
      _operationGetter(operation.resolvedMethodName);

  Method _operationGetter(String name) {
    final className = _operationClassName(name);
    return Method(
      (builder) => builder
        ..type = MethodType.getter
        ..returns = refer(className)
        ..name = name
        ..body = refer(className).newInstance([refer('this')]).returned.statement,
    );
  }

  Constructor _clientConstructor() {
    return Constructor((builder) {
      builder.optionalParameters.addAll([
        _superParameter('baseUri', required: true),
        _superParameter('transport', required: true),
        _superParameter('webSocketTransport'),
        _superParameter('webTransportTransport'),
        _superParameter(
          'defaultHeaders',
          defaultTo: literalConstMap(
            const <String, String>{},
            refer('String'),
            refer('String'),
          ).code,
        ),
      ]);
    });
  }

  Method _operationMethod(DartHttpClientOperation operation, {required String name}) {
    return Method((builder) {
      builder
        ..returns = _isSseOperation(operation)
            ? _type('Future', [refer('DartHttpClientStreamedResponseObject')])
            : _type('Future', [
                _type('DartHttpClientResponseObject', [refer(operation.successType)]),
              ])
        ..name = name
        ..optionalParameters.addAll(_operationParameters(operation))
        ..body =
            (_isSseOperation(operation)
                    ? _invokeStreamExpression(operation)
                    : _invokeExpression(operation))
                .returned
                .statement;
    });
  }

  Method _operationStartMethod(DartHttpClientOperation operation) {
    final responseType = _isSseOperation(operation)
        ? 'DartHttpClientStreamedResponseObject'
        : 'DartHttpClientResponseObject<${operation.successType}>';
    final forwarded = <String>[
      if (operation.paramsType != null) 'params: params',
      if (operation.queryType != null) 'query: query',
      if (operation.headersType != null) 'headers: headers',
      if (operation.bodyType != null) 'body: body',
      'abortTrigger: abortTrigger',
      if (_isMultipartOperation(operation)) 'onUploadProgress: onUploadProgress',
    ].join(',\n');
    return Method(
      (builder) => builder
        ..returns = refer('DartHttpClientRequestHandle<$responseType>')
        ..name = 'start'
        ..optionalParameters.addAll(
          _operationParameters(operation).where((parameter) => parameter.name != 'abortTrigger'),
        )
        ..body = Code('''
return startDartHttpClientRequest<$responseType>(
  info: info,
  timeout: timeout,
  run: (abortTrigger) => call(
$forwarded,
  ),
);
'''),
    );
  }

  Method _binaryStreamOperationMethod(DartHttpClientOperation operation, {required String name}) {
    return Method((builder) {
      builder
        ..returns = _type('Future', [refer('DartHttpClientStreamedResponseObject')])
        ..name = name
        ..optionalParameters.addAll(_operationParameters(operation))
        ..body = _invokeStreamExpression(operation).returned.statement;
    });
  }

  Iterable<Parameter> _operationParameters(DartHttpClientOperation operation) {
    return <Parameter>[
      if (operation.paramsType case final type?)
        _namedParameter('params', type: refer(type), required: true),
      if (operation.queryType case final type?) _namedParameter('query', type: refer('$type?')),
      if (operation.headersType case final type?) _namedParameter('headers', type: refer('$type?')),
      if (operation.bodyType case final type?)
        _namedParameter('body', type: refer(type), required: true),
      _namedParameter('abortTrigger', type: refer('Future<void>?')),
      _namedParameter('timeout', type: refer('Duration?')),
      if (_isMultipartOperation(operation))
        _namedParameter(
          'onUploadProgress',
          type: refer('void Function(DartHttpMultipartUploadProgress progress)?'),
        ),
    ];
  }

  Expression _invokeExpression(DartHttpClientOperation operation) {
    final invocationTypes = _invocationTypes(operation);
    final invocation = refer('DartHttpClientInvocation')
        .newInstance(const <Expression>[], _invocationArguments(operation), invocationTypes);

    return refer('_client')
        .property('invoke')
        .call(<Expression>[invocation], const <String, Expression>{}, invocationTypes);
  }

  Expression _invokeStreamExpression(DartHttpClientOperation operation) {
    final invocationTypes = <Reference>[refer('Object?'), ..._invocationTypes(operation).skip(1)];
    final invocation = refer('DartHttpClientInvocation')
        .newInstance(const <Expression>[], _invocationArguments(operation), invocationTypes);

    return refer('_client')
        .property('invokeStream')
        .call(
          <Expression>[invocation],
          const <String, Expression>{},
          invocationTypes.skip(1).toList(),
        );
  }

  Method _webSocketMethod(DartHttpClientWebSocketOperation operation, {required String name}) {
    final invocationTypes = _webSocketInvocationTypes(operation);
    return Method((builder) {
      builder
        ..returns = _type('Future', [refer('DartHttpClientWebSocket')])
        ..name = name
        ..optionalParameters.addAll([
          ..._webSocketParameters(operation),
          _namedParameter(
            'protocols',
            type: _type('List', [refer('String')]),
            defaultTo: const Code('const <String>[]'),
          ),
        ])
        ..body = refer('_client')
            .property('connectWebSocket')
            .call(
              [
                refer('DartHttpClientWebSocketInvocation').newInstance(const <Expression>[], {
                  'pathTemplate': literalString(operation.path),
                  if (operation.paramsType != null)
                    'params': _requestValueExpression(
                      type: operation.paramsType!,
                      schemaId: jsonSchemaRouteId(operation.params),
                      value: refer('params'),
                      encode: _encoderFor(operation.paramsType!),
                    ),
                  if (operation.queryType != null)
                    'query': _requestValueExpression(
                      type: '${operation.queryType}?',
                      schemaId: jsonSchemaRouteId(operation.query),
                      value: refer('query'),
                      encode: _nullableEncoderFor(operation.queryType!),
                    ),
                  if (operation.headersType != null)
                    'headers': _requestValueExpression(
                      type: '${operation.headersType}?',
                      schemaId: null,
                      value: refer('headers'),
                      encode: _nullableEncoderFor(operation.headersType!),
                    ),
                  'protocols': refer('protocols'),
                }, invocationTypes),
              ],
              const <String, Expression>{},
              invocationTypes,
            )
            .returned
            .statement;
    });
  }

  Iterable<Parameter> _webSocketParameters(DartHttpClientWebSocketOperation operation) {
    return <Parameter>[
      if (operation.paramsType case final type?)
        _namedParameter('params', type: refer(type), required: true),
      if (operation.queryType case final type?) _namedParameter('query', type: refer('$type?')),
      if (operation.headersType case final type?) _namedParameter('headers', type: refer('$type?')),
    ];
  }

  List<Reference> _webSocketInvocationTypes(DartHttpClientWebSocketOperation operation) {
    return <Reference>[
      refer(operation.paramsType ?? 'Never'),
      refer(operation.queryType == null ? 'Never' : '${operation.queryType}?'),
      refer(operation.headersType == null ? 'Never' : '${operation.headersType}?'),
    ];
  }

  Method _webTransportMethod(
    DartHttpClientWebTransportOperation operation, {
    required String name,
  }) {
    final invocationTypes = _webTransportInvocationTypes(operation);
    return Method((builder) {
      builder
        ..returns = _type('Future', [refer('DartHttpClientWebTransportSession')])
        ..name = name
        ..optionalParameters.addAll(_webTransportParameters(operation))
        ..body = refer('_client')
            .property('connectWebTransport')
            .call(
              [
                refer('DartHttpClientWebTransportInvocation').newInstance(const <Expression>[], {
                  'pathTemplate': literalString(operation.path),
                  if (operation.paramsType != null)
                    'params': _requestValueExpression(
                      type: operation.paramsType!,
                      schemaId: null,
                      value: refer('params'),
                      encode: _encoderFor(operation.paramsType!),
                    ),
                  if (operation.queryType != null)
                    'query': _requestValueExpression(
                      type: '${operation.queryType}?',
                      schemaId: null,
                      value: refer('query'),
                      encode: _nullableEncoderFor(operation.queryType!),
                    ),
                  if (operation.headersType != null)
                    'headers': _requestValueExpression(
                      type: '${operation.headersType}?',
                      schemaId: null,
                      value: refer('headers'),
                      encode: _nullableEncoderFor(operation.headersType!),
                    ),
                }, invocationTypes),
              ],
              const <String, Expression>{},
              invocationTypes,
            )
            .returned
            .statement;
    });
  }

  Iterable<Parameter> _webTransportParameters(DartHttpClientWebTransportOperation operation) {
    return <Parameter>[
      if (operation.paramsType case final type?)
        _namedParameter('params', type: refer(type), required: true),
      if (operation.queryType case final type?) _namedParameter('query', type: refer('$type?')),
      if (operation.headersType case final type?) _namedParameter('headers', type: refer('$type?')),
    ];
  }

  List<Reference> _webTransportInvocationTypes(DartHttpClientWebTransportOperation operation) {
    return <Reference>[
      refer(operation.paramsType ?? 'Never'),
      refer(operation.queryType == null ? 'Never' : '${operation.queryType}?'),
      refer(operation.headersType == null ? 'Never' : '${operation.headersType}?'),
    ];
  }

  List<Reference> _invocationTypes(DartHttpClientOperation operation) {
    return <Reference>[
      refer(operation.successType),
      refer(operation.paramsType ?? 'Never'),
      refer(operation.queryType == null ? 'Never' : '${operation.queryType}?'),
      refer(operation.headersType == null ? 'Never' : '${operation.headersType}?'),
      refer(operation.bodyType ?? 'Never'),
    ];
  }

  Map<String, Expression> _invocationArguments(DartHttpClientOperation operation) {
    final options = operation.options;
    final successSchemaId = jsonSchemaRouteId(options.responses.success.schema);
    final arguments = <String, Expression>{
      'method': refer('HttpMethod').property(operation.method.name),
      'pathTemplate': literalString(operation.path),
      'abortTrigger': refer('abortTrigger'),
      'timeout': refer('timeout'),
      if (_isMultipartOperation(operation)) 'onMultipartUploadProgress': refer('onUploadProgress'),
      'success': refer('DartHttpClientResponseSpec').newInstance(
        const <Expression>[],
        <String, Expression>{
          'status': literalNum(options.responses.success.status),
          'contentType': literalString(options.responses.success.contentType),
          if (successSchemaId case final schemaId?) 'schemaId': literalString(schemaId),
          if (!_isRawTransportType(operation.successType))
            'decoder': refer(operation.successType).property('decode'),
        },
        <Reference>[refer(operation.successType)],
      ),
      if (options.responses.errors.isNotEmpty)
        'errors': literalList([
          for (final error in options.responses.errors)
            refer('DartHttpClientErrorSpec').newInstance(const <Expression>[], <String, Expression>{
              'status': literalNum(error.status),
              if (error.code case final code?) 'code': literalString(code),
            }),
        ], refer('DartHttpClientErrorSpec')),
    };

    if (options.params case final schema?) {
      arguments['params'] = _requestValueExpression(
        type: operation.paramsType!,
        schemaId: jsonSchemaRouteId(schema),
        value: refer('params'),
        encode: _encoderFor(operation.paramsType!),
      );
    }
    if (options.query case final schema?) {
      arguments['query'] = _requestValueExpression(
        type: '${operation.queryType}?',
        schemaId: jsonSchemaRouteId(schema),
        value: refer('query'),
        encode: _nullableEncoderFor(operation.queryType!),
      );
    }
    if (options.headers case final schema?) {
      arguments['headers'] = _requestValueExpression(
        type: '${operation.headersType}?',
        schemaId: jsonSchemaRouteId(schema),
        value: refer('headers'),
        encode: _nullableEncoderFor(operation.headersType!),
      );
    }
    if (options.body case final body?) {
      final bodySchemaId = jsonSchemaRouteId(body.schema);
      final bodyEncoder = _isMultipartFormDataContentType(body.contentType)
          ? const CodeExpression(Code('(value) => value.toMultipartFormData()'))
          : _encoderFor(operation.bodyType!);
      arguments['body'] = refer('DartHttpClientRequestBody').newInstance(
        const <Expression>[],
        <String, Expression>{
          'contentType': literalString(body.contentType),
          if (bodySchemaId case final schemaId?) 'schemaId': literalString(schemaId),
          'value': refer('body'),
          'encoder': ?bodyEncoder,
        },
        <Reference>[refer(operation.bodyType!)],
      );
    }

    return arguments;
  }
}

final class _ClientModelFieldSpec {
  const _ClientModelFieldSpec({
    required this.wireName,
    required this.name,
    required this.schema,
    required this.required,
    required this.type,
    required this.schemaTypes,
  });

  final String wireName;
  final String name;
  final JsonSchema schema;
  final bool required;
  final String type;
  final Map<String, String> schemaTypes;
}

enum _ClientModelSource { json, multipart }

Set<String> _multipartBodySchemaIds(DartHttpClientLibrarySpec spec) {
  return {
    for (final operation in spec.operations)
      if (operation.options.body case final body?
          when _isMultipartFormDataContentType(body.contentType))
        ?_clientSchemaTypeId(body.schema),
  };
}

bool _isMultipartOperation(DartHttpClientOperation operation) {
  final body = operation.options.body;
  return body != null && _isMultipartFormDataContentType(body.contentType);
}

bool _isMultipartFormDataContentType(String contentType) {
  return contentType.split(';').first.trim().toLowerCase() == 'multipart/form-data';
}

bool _isMultipartBinaryField(JsonSchema schema) {
  return (schema is JsonStringSchema && schema.format == 'binary') ||
      (schema is JsonArraySchema &&
          schema.items is JsonStringSchema &&
          (schema.items! as JsonStringSchema).format == 'binary');
}

String _multipartTextFieldExpression(_ClientModelFieldSpec field) {
  final name = field.name;
  final wireName = _dartString(field.wireName);
  if (field.schema case JsonArraySchema(:final items)) {
    final value = _multipartTextValueExpression(
      items ?? const JsonSchema.any(),
      'value',
      field.schemaTypes,
    );
    if (field.required) {
      return '    for (final value in $name) '
          'MultipartFormField(name: $wireName, value: $value),';
    }
    return '    if ($name != null) for (final value in $name!) '
        'MultipartFormField(name: $wireName, value: $value),';
  }
  final value = _multipartTextValueExpression(field.schema, name, field.schemaTypes);
  final nullableValue = _multipartTextValueExpression(field.schema, '$name!', field.schemaTypes);
  if (field.required) {
    return '    MultipartFormField(name: $wireName, value: $value),';
  }
  return '    if ($name != null) MultipartFormField(name: $wireName, value: $nullableValue),';
}

String _multipartTextValueExpression(
  JsonSchema schema,
  String value,
  Map<String, String> schemaTypes,
) {
  final encoded = _encodeSchemaValue(schema, value, nullable: false, schemaTypes: schemaTypes);
  return '$encoded.toString()';
}

String _multipartFileExpression(_ClientModelFieldSpec field) {
  final name = field.name;
  final wireName = _dartString(field.wireName);
  if (field.schema case JsonArraySchema()) {
    if (field.required) {
      return '    for (final file in $name) file.asFile($wireName),';
    }
    return '    if ($name != null) for (final file in $name!) '
        'file.asFile($wireName),';
  }
  if (field.required) {
    return '    $name.asFile($wireName),';
  }
  return '    if ($name != null) $name!.asFile($wireName),';
}

String _dartString(String value) => jsonEncode(value);

String _clientModelType(
  JsonSchema schema, {
  required bool nullable,
  required Map<String, String> schemaTypes,
  _ClientModelSource source = _ClientModelSource.json,
}) {
  final baseType = switch (schema) {
    JsonReferenceSchema _ => _schemaTypeFromId(jsonSchemaRouteId(schema), schemaTypes) ?? 'Object?',
    JsonStringSchema(:final dartType, :final format) => _clientStringModelType(
      dartType,
      format: format,
      source: source,
    ),
    JsonIntegerSchema _ => 'int',
    JsonNumberSchema _ => 'num',
    JsonBooleanSchema _ => 'bool',
    JsonArraySchema _ =>
      'List<${_clientModelType(schema.items ?? const JsonSchema.any(), nullable: false, schemaTypes: schemaTypes, source: source)}>',
    JsonCompositeSchema(:final dartType) => _clientDartTypeName(dartType) ?? 'Object?',
    JsonObjectSchema(:final id?) => _schemaTypeFromId(id, schemaTypes)!,
    JsonObjectSchema _ => 'Map<String, Object?>',
    JsonAnySchema _ => 'Object?',
    JsonRawSchema _ => 'Object?',
    _ => 'Object?',
  };
  if (nullable || schema.nullable) {
    if (baseType.endsWith('?')) {
      return baseType;
    }
    return '$baseType?';
  }
  return baseType;
}

String _decodeSchemaValue(JsonSchema schema, String value, Map<String, String> schemaTypes) {
  return switch (schema) {
    JsonReferenceSchema _ => _decodeClientModelValue(
      _schemaTypeFromId(jsonSchemaRouteId(schema), schemaTypes),
      value,
    ),
    JsonStringSchema(:final dartType, :final format) => _decodeClientStringValue(
      dartType,
      value,
      format: format,
    ),
    JsonIntegerSchema _ => '($value as num).toInt()',
    JsonNumberSchema _ => '$value as num',
    JsonBooleanSchema _ => '$value as bool',
    JsonArraySchema _ =>
      '($value as List).map((item) => ${_decodeSchemaValue(schema.items ?? const JsonSchema.any(), 'item', schemaTypes)}).toList(growable: false)',
    JsonCompositeSchema(:final dartType) => _decodeClientCustomValue(dartType, value),
    JsonObjectSchema(:final id?) => _decodeClientModelValue(
      _schemaTypeFromId(id, schemaTypes),
      value,
    ),
    JsonObjectSchema _ => 'readJsonObject($value)',
    JsonAnySchema _ => value,
    JsonRawSchema _ => value,
    _ => value,
  };
}

String _decodeClientModelValue(String? type, String value) {
  if (type == null || _isRawTransportType(type)) {
    return 'readJsonObject($value)';
  }
  return '$type.decode($value)';
}

String _encodeSchemaValue(
  JsonSchema schema,
  String value, {
  required bool nullable,
  required Map<String, String> schemaTypes,
}) {
  return switch (schema) {
    JsonReferenceSchema _ => _encodeClientModelValue(
      _schemaTypeFromId(jsonSchemaRouteId(schema), schemaTypes),
      value,
      nullable: nullable,
    ),
    JsonObjectSchema(:final id?) => _encodeClientModelValue(
      _schemaTypeFromId(id, schemaTypes),
      value,
      nullable: nullable,
    ),
    JsonStringSchema(:final dartType, :final format) => _encodeClientStringValue(
      dartType,
      value,
      nullable: nullable,
      format: format,
    ),
    JsonArraySchema(:final items?) => _encodeArrayValue(
      items,
      value,
      nullable: nullable,
      schemaTypes: schemaTypes,
    ),
    JsonCompositeSchema(:final dartType) => _encodeClientCustomValue(
      dartType,
      value,
      nullable: nullable,
    ),
    _ => value,
  };
}

String _decodeClientStringValue(DartSchemaType? dartType, String value, {required String? format}) {
  if (dartType == null) {
    if (format == 'date-time') {
      return 'DateTime.parse($value as String)';
    }
    return '$value as String';
  }

  final typeName = _clientDartTypeName(dartType);
  if (typeName == null) {
    return '$value as String';
  }
  return switch (dartType) {
    DartConcreteSchemaType() || DartNamedSchemaType() => switch (_clientDartSchemaConversion(
      dartType,
      defaultConversion: DartSchemaConversion.value,
    )) {
      DartSchemaConversion.value => '$typeName($value as String)',
      DartSchemaConversion.model => '$typeName.decode($value)',
      DartSchemaConversion.infer => throw StateError(
        'Dart schema conversion inference should be resolved.',
      ),
    },
    DartGenericSchemaType() => '$value as $typeName',
  };
}

String _encodeClientStringValue(
  DartSchemaType? dartType,
  String value, {
  required bool nullable,
  required String? format,
}) {
  if (dartType == null) {
    if (format == 'date-time') {
      return nullable ? '$value?.toIso8601String()' : '$value.toIso8601String()';
    }
    return value;
  }

  return switch (dartType) {
    DartConcreteSchemaType() || DartNamedSchemaType() => switch (_clientDartSchemaConversion(
      dartType,
      defaultConversion: DartSchemaConversion.value,
    )) {
      DartSchemaConversion.value => nullable ? '$value?.value' : '$value.value',
      DartSchemaConversion.model => nullable ? '$value?.toJson()' : '$value.toJson()',
      DartSchemaConversion.infer => throw StateError(
        'Dart schema conversion inference should be resolved.',
      ),
    },
    DartGenericSchemaType() => value,
  };
}

String _decodeClientCustomValue(DartSchemaType? dartType, String value) {
  final typeName = _clientDartTypeName(dartType);
  if (typeName == null) {
    return value;
  }
  if (dartType case DartGenericSchemaType()) {
    return '$value as $typeName';
  }
  return switch (_clientDartSchemaConversion(
    dartType!,
    defaultConversion: DartSchemaConversion.model,
  )) {
    DartSchemaConversion.value => '$typeName($value)',
    DartSchemaConversion.model => '$typeName.decode($value)',
    DartSchemaConversion.infer => throw StateError(
      'Dart schema conversion inference should be resolved.',
    ),
  };
}

String _encodeClientCustomValue(DartSchemaType? dartType, String value, {required bool nullable}) {
  if (dartType == null || dartType is DartGenericSchemaType) {
    return value;
  }
  return switch (_clientDartSchemaConversion(
    dartType,
    defaultConversion: DartSchemaConversion.model,
  )) {
    DartSchemaConversion.value => nullable ? '$value?.value' : '$value.value',
    DartSchemaConversion.model => nullable ? '$value?.toJson()' : '$value.toJson()',
    DartSchemaConversion.infer => throw StateError(
      'Dart schema conversion inference should be resolved.',
    ),
  };
}

String _encodeClientModelValue(String? type, String value, {required bool nullable}) {
  if (type == null || _isRawTransportType(type)) {
    return value;
  }
  return nullable ? '$value?.toJson()' : '$value.toJson()';
}

String _clientStringModelType(
  DartSchemaType? dartType, {
  String? format,
  _ClientModelSource source = _ClientModelSource.json,
}) {
  if (source == _ClientModelSource.multipart && format == 'binary') {
    return 'MultipartUploadFile';
  }
  return _clientDartTypeName(dartType) ??
      switch (format) {
        'date-time' => 'DateTime',
        _ => 'String',
      };
}

String? _clientDartTypeName(DartSchemaType? dartType) {
  return switch (dartType) {
    DartConcreteSchemaType(:final name, :final type) => name ?? type?.toString(),
    DartNamedSchemaType(:final name) => name,
    DartGenericSchemaType(:final name) => name,
    null => null,
  };
}

DartSchemaConversion _clientDartSchemaConversion(
  DartSchemaType dartType, {
  required DartSchemaConversion defaultConversion,
}) {
  final conversion = switch (dartType) {
    DartConcreteSchemaType(:final conversion) ||
    DartNamedSchemaType(:final conversion) => conversion,
    DartGenericSchemaType() => DartSchemaConversion.infer,
  };
  return conversion == DartSchemaConversion.infer ? defaultConversion : conversion;
}

String _encodeArrayValue(
  JsonSchema items,
  String value, {
  required bool nullable,
  required Map<String, String> schemaTypes,
}) {
  final encoded = _encodeSchemaValue(items, 'item', nullable: false, schemaTypes: schemaTypes);
  if (encoded == 'item') {
    return value;
  }
  final receiver = nullable ? '$value?' : value;
  return '$receiver.map((item) => $encoded).toList(growable: false)';
}

Expression _requestValueExpression({
  required String type,
  required String? schemaId,
  required Expression value,
  Expression? encode,
}) {
  return refer('DartHttpClientRequestValue').newInstance(
    const <Expression>[],
    <String, Expression>{
      if (schemaId case final schemaId?) 'schemaId': literalString(schemaId),
      'value': value,
      'encoder': ?encode,
    },
    <Reference>[refer(type)],
  );
}

Expression? _encoderFor(String type) {
  if (_isRawTransportType(type)) {
    return null;
  }
  return const CodeExpression(Code('(value) => value.toJson()'));
}

Expression? _nullableEncoderFor(String type) {
  if (_isRawTransportType(type)) {
    return null;
  }
  return const CodeExpression(Code('(value) => value?.toJson()'));
}

bool _isRawTransportType(String type) {
  return type == 'Map<String, Object?>' ||
      type == 'Map<String, String>' ||
      type == 'Uint8List' ||
      type == 'String' ||
      type == 'int' ||
      type == 'double' ||
      type == 'num' ||
      type == 'bool' ||
      type == 'Object?' ||
      type == 'Object';
}

final class _ClientSchemaCollector {
  _ClientSchemaCollector(Iterable<JsonSchema> schemas) {
    for (final schema in schemas) {
      add(schema);
    }
  }

  final Map<String, JsonSchema> _schemasById = <String, JsonSchema>{};

  List<JsonSchema> get schemas => List<JsonSchema>.unmodifiable(_schemasById.values);

  void addRouteOptions(RouteOptions options) {
    add(options.params);
    add(options.query);
    add(options.headers);
    add(options.body?.schema);
    add(options.responses.success.schema);
  }

  void addWebSocketOptions(WebSocketOptions options) {
    add(options.params);
    add(options.query);
  }

  void add(JsonSchema? schema) {
    if (schema == null) {
      return;
    }

    if (schema case JsonSchema(:final id?)) {
      _schemasById.putIfAbsent(id, () => schema);
    }

    switch (schema) {
      case JsonObjectSchema(:final properties):
        for (final property in properties.values) {
          add(property);
        }
      case JsonArraySchema(:final items?):
        add(items);
      case JsonCompositeSchema(:final schemas):
        for (final schema in schemas) {
          add(schema);
        }
      case _:
        break;
    }
  }
}

DartHttpClientOperation _operationFromOptions({
  required HttpMethod method,
  required String path,
  required RouteOptions options,
  required Map<String, String> schemaTypes,
  String? methodName,
}) {
  final operationId = options.operationId!;
  return DartHttpClientOperation(
    method: method,
    path: path,
    options: options,
    successType:
        _schemaTypeForOperation(
          operationId: operationId,
          path: path,
          field: 'success',
          schema: options.success?.schema,
          schemaTypes: schemaTypes,
        ) ??
        _defaultSuccessType(options.success),
    methodName: methodName,
    paramsType: _schemaTypeForOperation(
      operationId: operationId,
      path: path,
      field: 'params',
      schema: options.params,
      schemaTypes: schemaTypes,
    ),
    queryType: _schemaTypeForOperation(
      operationId: operationId,
      path: path,
      field: 'query',
      schema: options.query,
      schemaTypes: schemaTypes,
    ),
    headersType: _schemaTypeForOperation(
      operationId: operationId,
      path: path,
      field: 'headers',
      schema: options.headers,
      schemaTypes: schemaTypes,
    ),
    bodyType: options.body == null
        ? null
        : _schemaTypeForOperation(
                operationId: operationId,
                path: path,
                field: 'body',
                schema: options.body?.schema,
                schemaTypes: schemaTypes,
              ) ??
              'Object?',
  );
}

DartHttpClientWebSocketOperation _webSocketOperationFromOptions({
  required String path,
  required WebSocketOptions options,
  required Map<String, String> schemaTypes,
  String? methodName,
}) {
  final operationId = options.operationId!;
  return DartHttpClientWebSocketOperation(
    path: path,
    operationId: operationId,
    methodName: methodName,
    params: options.params,
    paramsType: _schemaTypeForOperation(
      operationId: operationId,
      path: path,
      field: 'params',
      schema: options.params,
      schemaTypes: schemaTypes,
    ),
    query: options.query,
    queryType: _schemaTypeForOperation(
      operationId: operationId,
      path: path,
      field: 'query',
      schema: options.query,
      schemaTypes: schemaTypes,
    ),
  );
}

RouteOptions _effectiveRouteOptions<TServices>(
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

WebSocketOptions _effectiveWebSocketOptions<TServices>(
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
  );
}

WebTransportOptions _effectiveWebTransportOptions<TServices>(
  RouteRegistration<TServices> registration,
  WebTransportOptions options,
) {
  return WebTransportOptions(
    operationId: options.operationId,
    summary: options.summary,
    tags: _mergeTags(registration.tags, options.tags),
    deprecated: options.deprecated,
    exposure: registration.exposure.restrict(options.exposure),
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

String? _schemaType(JsonSchema? schema, Map<String, String> schemaTypes) {
  final schemaId = _clientSchemaTypeId(schema);
  if (schemaId == null) {
    return switch (schema) {
      JsonStringSchema(:final format) => format == 'binary' ? 'Uint8List' : 'String',
      JsonIntegerSchema _ => 'int',
      JsonNumberSchema _ => 'num',
      JsonBooleanSchema _ => 'bool',
      JsonArraySchema _ => _clientModelType(schema, nullable: false, schemaTypes: schemaTypes),
      JsonCompositeSchema _ => _clientModelType(schema, nullable: false, schemaTypes: schemaTypes),
      JsonObjectSchema _ => 'Map<String, Object?>',
      JsonAnySchema _ => 'Object?',
      JsonRawSchema _ => 'Object?',
      _ => null,
    };
  }
  return _schemaTypeFromId(schemaId, schemaTypes);
}

String? _schemaTypeForOperation({
  required String operationId,
  required String path,
  required String field,
  required JsonSchema? schema,
  required Map<String, String> schemaTypes,
}) {
  if (schema == null) {
    return null;
  }
  final type = _schemaType(schema, schemaTypes);
  if (type != null) {
    return type;
  }
  throw StateError(
    'Unable to resolve Dart client type for $field schema on operation '
    '"$operationId" ($path): ${_schemaDescription(schema)}. Use a supported '
    'JsonSchema.ref/componentRef, add an inline schema id, or provide a '
    'schemaTypes override.',
  );
}

String _schemaDescription(JsonSchema schema) {
  return switch (schema) {
    JsonReferenceSchema(:final ref) => 'ref "$ref"',
    JsonSchema(:final id?) => 'id "$id"',
    _ => schema.runtimeType.toString(),
  };
}

String? _clientSchemaTypeId(JsonSchema? schema) {
  return switch (schema) {
    null => null,
    JsonReferenceSchema _ => jsonSchemaRouteId(schema),
    JsonObjectSchema(:final id?) => id,
    JsonArraySchema(:final id?) => id,
    JsonStringSchema(:final id?) => id,
    JsonIntegerSchema(:final id?) => id,
    JsonNumberSchema(:final id?) => id,
    JsonBooleanSchema(:final id?) => id,
    JsonAnySchema(:final id?) => id,
    JsonCompositeSchema(:final id?) => id,
    JsonRawSchema(:final id?) => id,
    _ => null,
  };
}

String? _schemaTypeFromId(String? id, Map<String, String> schemaTypes) {
  if (id == null) {
    return null;
  }
  return schemaTypes[id] ?? id;
}

String _defaultSuccessType(ResponseSpec? response) {
  if (response == null) {
    return 'Object?';
  }
  final contentType = response.contentType.toLowerCase();
  if (contentType.startsWith('text/plain')) {
    return 'String';
  }
  if (_isBinaryContentType(contentType)) {
    return 'Uint8List';
  }
  return 'Object?';
}

bool _isBinaryContentType(String contentType) {
  final mimeType = contentType.split(';').first.trim().toLowerCase();
  return mimeType == 'application/octet-stream' ||
      mimeType.startsWith('audio/') ||
      mimeType.startsWith('image/') ||
      mimeType.startsWith('video/');
}

bool _isSseOperation(DartHttpClientOperation operation) {
  return _isSseContentType(operation.options.responses.success.contentType);
}

bool _isBinaryOperation(DartHttpClientOperation operation) {
  return operation.successType == 'Uint8List';
}

bool _isSseContentType(String contentType) {
  return contentType.split(';').first.trim().toLowerCase() == 'text/event-stream';
}

bool _needsTypedDataImport(DartHttpClientLibrarySpec spec) {
  for (final operation in spec.operations) {
    if (operation.successType == 'Uint8List' ||
        operation.paramsType == 'Uint8List' ||
        operation.queryType == 'Uint8List' ||
        operation.headersType == 'Uint8List' ||
        operation.bodyType == 'Uint8List') {
      return true;
    }
  }
  for (final operation in spec.webSockets) {
    if (operation.paramsType == 'Uint8List' ||
        operation.queryType == 'Uint8List' ||
        operation.headersType == 'Uint8List') {
      return true;
    }
  }
  for (final operation in spec.webTransports) {
    if (operation.paramsType == 'Uint8List' ||
        operation.queryType == 'Uint8List' ||
        operation.headersType == 'Uint8List') {
      return true;
    }
  }
  return false;
}

bool _matchesPathPrefix(String path, String prefix) {
  final normalizedPrefix = _normalizeIgnoredPath(prefix);
  if (path == normalizedPrefix) {
    return true;
  }
  if (normalizedPrefix == '/') {
    return path.startsWith('/');
  }
  return path.startsWith('$normalizedPrefix/');
}

String _normalizeIgnoredPath(String path) {
  if (path == '/') {
    return path;
  }
  return path.endsWith('/') ? path.substring(0, path.length - 1) : path;
}

String? _prefixedMethodName(String routePrefix, String operationId) {
  final normalizedPrefix = _normalizeIgnoredPath(routePrefix);
  if (normalizedPrefix.isEmpty || normalizedPrefix == '/') {
    return null;
  }

  final prefix = _lowerCamel(normalizedPrefix);
  if (prefix.isEmpty || operationId.startsWith(prefix)) {
    return null;
  }

  final operationName = _lowerCamel(operationId);
  if (operationName.isEmpty) {
    return prefix;
  }
  return '$prefix${operationName[0].toUpperCase()}${operationName.substring(1)}';
}

String? _pathPrefixedMethodName(String fullPath, String operationId, Set<String> pathPrefixes) {
  final matchingPrefixes = [
    for (final pathPrefix in pathPrefixes)
      if (_matchesPathPrefix(fullPath, pathPrefix)) _normalizeIgnoredPath(pathPrefix),
  ]..sort((left, right) => right.length.compareTo(left.length));

  if (matchingPrefixes.isEmpty) {
    return null;
  }
  return _prefixedMethodName(matchingPrefixes.first, operationId);
}

Parameter _superParameter(String name, {bool required = false, Code? defaultTo}) {
  return Parameter((builder) {
    builder
      ..name = name
      ..named = true
      ..toSuper = true
      ..required = required
      ..defaultTo = defaultTo;
  });
}

Parameter _namedParameter(
  String name, {
  Reference? type,
  bool required = false,
  Code? defaultTo,
  bool toThis = false,
}) {
  return Parameter((builder) {
    builder
      ..name = name
      ..named = true
      ..type = type
      ..required = required
      ..defaultTo = defaultTo
      ..toThis = toThis;
  });
}

TypeReference _type(String symbol, [Iterable<Reference> types = const []]) {
  return TypeReference((builder) {
    builder
      ..symbol = symbol
      ..types.addAll(types);
  });
}

String _format(Library library, {required DartHttpClientFormatterOptions formatterOptions}) {
  return formatterOptions.createFormatter().format('${library.accept(DartEmitter())}');
}

String _lowerCamel(String value) {
  if (value.isEmpty) {
    return value;
  }
  final parts = value
      .split(RegExp(r'[^A-Za-z0-9]+'))
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  if (parts.isEmpty) {
    return value;
  }
  final first = parts.first;
  return [
    '${first[0].toLowerCase()}${first.substring(1)}',
    for (final part in parts.skip(1)) '${part[0].toUpperCase()}${part.substring(1)}',
  ].join();
}

String _operationClassName(String methodName) {
  if (methodName.isEmpty) {
    throw ArgumentError.value(methodName, 'methodName', 'Must not be empty.');
  }
  return '${methodName[0].toUpperCase()}${methodName.substring(1)}Operation';
}
