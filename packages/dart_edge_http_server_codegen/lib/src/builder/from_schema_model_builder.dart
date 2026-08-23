import 'dart:convert';

import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:code_builder/code_builder.dart';
import 'package:dart_style/dart_style.dart';
import 'package:json_schema/json_schema.dart';
import 'package:source_gen/source_gen.dart';

/// Build-time description of a model generated from a JSON Schema.
final class FromSchemaModelSpec {
  const FromSchemaModelSpec({
    required this.publicName,
    required this.backingClassName,
    required this.schema,
    required this.schemaId,
    required this.refModels,
    required this.typeParameters,
    required this.schemasById,
    required this.responseStatus,
    required this.source,
  });

  final String publicName;
  final String backingClassName;
  final JsonSchema schema;
  final String schemaId;
  final Map<String, SchemaRefModelSpec> refModels;
  final List<TypeParameterSpec> typeParameters;
  final Map<String, JsonSchema> schemasById;
  final int responseStatus;
  final FromSchemaModelSource source;
}

enum FromSchemaModelSource { json, multipart }

final class FromSchemaFormatterOptions {
  const FromSchemaFormatterOptions({this.pageWidth, this.trailingCommas});

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

FromSchemaModelSpec buildFromSchemaModel(
  Element element,
  ConstantReader reader, {
  FromSchemaModelSource source = FromSchemaModelSource.json,
}) {
  if (element is! TypeAliasElement) {
    throw InvalidGenerationSourceError(
      '@${_annotationName(source)} can only be used on type aliases.',
      element: element,
    );
  }

  final sourceSchema = jsonSchemaFromDartObject(
    reader.read('schema').objectValue,
    element: element,
  );

  final registryReader = reader.read('registry');
  JsonSchemaRegistry? registry;
  if (!registryReader.isNull) {
    registry = _jsonSchemaRegistryFromDartObject(registryReader.objectValue, element: element);
  }

  final schema = _resolveRootSchema(sourceSchema, registry: registry, element: element);

  if (registry != null) {
    _validateSchemaReferences(schema, registry, element);
  }

  final refModels = _schemaRefModelsFromDartObject(
    reader.read('refs').objectValue,
    registry: registry,
    element: element,
  );
  final typeParameters = _typeParameterSpecs(element);
  final publicName = element.displayName;
  return FromSchemaModelSpec(
    publicName: publicName,
    backingClassName: '_\$$publicName',
    schema: schema,
    schemaId: _schemaIdForModel(sourceSchema, schema, publicName),
    refModels: refModels,
    typeParameters: typeParameters,
    schemasById: _schemasById(registry),
    responseStatus: reader.peek('responseStatus')?.intValue ?? 200,
    source: source,
  );
}

String _annotationName(FromSchemaModelSource source) {
  return switch (source) {
    FromSchemaModelSource.json => 'FromSchema',
    FromSchemaModelSource.multipart => 'FromMultipartSchema',
  };
}

JsonSchema jsonSchemaFromDartObject(DartObject object, {required Element element}) {
  final typeName = object.type?.element?.name;

  return switch (typeName) {
    'JsonAnySchema' => JsonSchema.any(
      id: _stringField(object, 'id'),
      title: _stringField(object, 'title'),
      description: _stringField(object, 'description'),
      enumValues: _objectListField(object, 'enumValues', element: element),
    ),
    'JsonObjectSchema' => JsonSchema.object(
      id: _stringField(object, 'id'),
      title: _stringField(object, 'title'),
      description: _stringField(object, 'description'),
      enumValues: _objectListField(object, 'enumValues', element: element),
      nullable: _boolField(object, 'nullable') ?? false,
      properties: _schemaMapField(object, 'properties', element: element),
      required: _stringListField(object, 'required'),
      additionalProperties: _boolField(object, 'additionalProperties'),
    ),
    'JsonArraySchema' => JsonSchema.array(
      id: _stringField(object, 'id'),
      title: _stringField(object, 'title'),
      description: _stringField(object, 'description'),
      enumValues: _objectListField(object, 'enumValues', element: element),
      nullable: _boolField(object, 'nullable') ?? false,
      items: switch (_field(object, 'items')) {
        final items? when !items.isNull => jsonSchemaFromDartObject(items, element: element),
        _ => null,
      },
    ),
    'JsonAnyOfSchema' => JsonSchema.anyOf(
      _schemaListField(object, 'schemas', element: element),
      id: _stringField(object, 'id'),
      title: _stringField(object, 'title'),
      description: _stringField(object, 'description'),
      enumValues: _objectListField(object, 'enumValues', element: element),
      nullable: _boolField(object, 'nullable') ?? false,
      dartType: _dartSchemaTypeField(object, 'dartType', element: element),
    ),
    'JsonOneOfSchema' => JsonSchema.oneOf(
      _schemaListField(object, 'schemas', element: element),
      id: _stringField(object, 'id'),
      title: _stringField(object, 'title'),
      description: _stringField(object, 'description'),
      enumValues: _objectListField(object, 'enumValues', element: element),
      nullable: _boolField(object, 'nullable') ?? false,
      dartType: _dartSchemaTypeField(object, 'dartType', element: element),
    ),
    'JsonAllOfSchema' => JsonSchema.allOf(
      _schemaListField(object, 'schemas', element: element),
      id: _stringField(object, 'id'),
      title: _stringField(object, 'title'),
      description: _stringField(object, 'description'),
      enumValues: _objectListField(object, 'enumValues', element: element),
      nullable: _boolField(object, 'nullable') ?? false,
      dartType: _dartSchemaTypeField(object, 'dartType', element: element),
    ),
    'JsonStringSchema' => JsonSchema.string(
      id: _stringField(object, 'id'),
      title: _stringField(object, 'title'),
      description: _stringField(object, 'description'),
      enumValues: _objectListField(object, 'enumValues', element: element),
      nullable: _boolField(object, 'nullable') ?? false,
      format: _stringField(object, 'format'),
      dartType: _dartSchemaTypeField(object, 'dartType', element: element),
    ),
    'JsonIntegerSchema' => JsonSchema.integer(
      id: _stringField(object, 'id'),
      title: _stringField(object, 'title'),
      description: _stringField(object, 'description'),
      enumValues: _objectListField(object, 'enumValues', element: element),
      nullable: _boolField(object, 'nullable') ?? false,
      format: _stringField(object, 'format'),
      minimum: _numField(object, 'minimum'),
      maximum: _numField(object, 'maximum'),
    ),
    'JsonNumberSchema' => JsonSchema.number(
      id: _stringField(object, 'id'),
      title: _stringField(object, 'title'),
      description: _stringField(object, 'description'),
      enumValues: _objectListField(object, 'enumValues', element: element),
      nullable: _boolField(object, 'nullable') ?? false,
      format: _stringField(object, 'format'),
      minimum: _numField(object, 'minimum'),
      maximum: _numField(object, 'maximum'),
    ),
    'JsonBooleanSchema' => JsonSchema.boolean(
      id: _stringField(object, 'id'),
      title: _stringField(object, 'title'),
      description: _stringField(object, 'description'),
      enumValues: _objectListField(object, 'enumValues', element: element),
      nullable: _boolField(object, 'nullable') ?? false,
    ),
    'JsonReferenceSchema' => JsonSchema.ref(
      _stringField(object, 'ref') ?? '',
      id: _stringField(object, 'id'),
      title: _stringField(object, 'title'),
      description: _stringField(object, 'description'),
      enumValues: _objectListField(object, 'enumValues', element: element),
    ),
    'JsonRawSchema' => JsonSchema.raw(
      _objectMapField(object, 'schema', element: element),
      id: _stringField(object, 'id'),
    ),
    _ => throw InvalidGenerationSourceError(
      '@FromSchema expected a const JsonSchema value, got $typeName.',
      element: element,
    ),
  };
}

Map<String, JsonSchema> _schemasById(JsonSchemaRegistry? registry) {
  if (registry == null) {
    return const <String, JsonSchema>{};
  }
  final schemas = <String, JsonSchema>{};
  for (final schema in registry.schemas) {
    final id = schema.id;
    if (id != null) {
      schemas[id] = schema;
    }
  }
  return schemas;
}

String generateFromSchemaModels(
  List<FromSchemaModelSpec> models, {
  FromSchemaFormatterOptions formatterOptions = const FromSchemaFormatterOptions(),
}) {
  final library = Library((builder) => builder.body.addAll(models.map(_modelSpec)));
  const ignoreForFile = '// ignore_for_file: unused_element, unused_field\n';
  return formatterOptions.createFormatter().format(
    '$ignoreForFile${library.accept(DartEmitter())}',
  );
}

Spec _modelSpec(FromSchemaModelSpec model) {
  return switch (model.schema) {
    JsonObjectSchema() => _objectModel(model),
    JsonStringSchema(:final enumValues) when enumValues.isNotEmpty => _stringEnumModel(model),
    JsonArraySchema() when !model.schema.nullable => _arrayModel(model),
    _ => throw StateError('Unsupported FromSchema model schema ${model.schema}.'),
  };
}

Class _objectModel(FromSchemaModelSpec model) {
  final fields = _modelFields(model);
  final publicType = _typeName(model.publicName, model.typeParameters);
  final isMultipart = model.source == FromSchemaModelSource.multipart;

  return Class((builder) {
    builder
      ..modifier = ClassModifier.final$
      ..name = model.backingClassName
      ..types.addAll(_typeParameterRefs(model.typeParameters))
      ..implements.addAll(isMultipart ? const [] : [refer('JsonEncodable')])
      ..constructors.add(
        Constructor((constructor) {
          constructor
            ..constant = true
            ..optionalParameters.addAll([
              for (final field in fields)
                Parameter((parameter) {
                  parameter
                    ..name = field.name
                    ..named = true
                    ..toThis = true
                    ..required = field.requiredParameter;
                }),
            ]);
        }),
      )
      ..constructors.addAll(
        model.typeParameters.isEmpty
            ? const <Constructor>[]
            : [
                _objectDecodeFactory(_typeName(model.backingClassName, model.typeParameters)),
                _objectFromJsonFactory(model, fields),
              ],
      )
      ..fields.addAll([
        _schemaIdField(model.schemaId),
        _schemaField(model.schema, schemaId: model.schemaId),
        _schemaRefField(),
        _requestBodyField(source: model.source, includeDecoder: model.typeParameters.isEmpty),
        if (!isMultipart) _responseField(model.responseStatus),
        for (final field in fields)
          Field((builder) {
            builder
              ..modifier = FieldModifier.final$
              ..type = refer(field.dartType)
              ..name = field.name;
          }),
      ])
      ..methods.addAll([
        if (!isMultipart) _objectToJsonMethod(fields, model.refModels),
        if (model.typeParameters.isEmpty)
          if (isMultipart)
            _objectFromMultipartMethod(model, fields)
          else ...[
            _decodeMethod(publicType, 'fromJson(readJsonObject(value))'),
            _objectFromJsonMethod(model, fields),
          ],
      ]);
  });
}

Enum _stringEnumModel(FromSchemaModelSpec model) {
  final schema = model.schema;
  if (schema is! JsonStringSchema) {
    throw StateError('Expected JsonStringSchema, got $schema.');
  }
  final values = _stringEnumValues(schema, model.publicName);

  return Enum((builder) {
    builder
      ..name = model.backingClassName
      ..implements.add(refer('JsonEncodable'))
      ..values.addAll([
        for (final value in values)
          EnumValue((builder) {
            builder
              ..name = value.name
              ..arguments.add(literalString(value.wireValue));
          }),
      ])
      ..constructors.add(
        Constructor((constructor) {
          constructor
            ..constant = true
            ..requiredParameters.add(
              Parameter((parameter) {
                parameter
                  ..name = 'value'
                  ..toThis = true;
              }),
            );
        }),
      )
      ..fields.addAll([
        Field((builder) {
          builder
            ..modifier = FieldModifier.final$
            ..type = refer('String')
            ..name = 'value';
        }),
        _schemaIdField(model.schemaId),
        _schemaField(model.schema, schemaId: model.schemaId),
        _schemaRefField(),
        _requestBodyField(source: model.source, includeDecoder: true),
        _responseField(model.responseStatus),
      ])
      ..methods.addAll([
        Method((builder) {
          builder
            ..annotations.add(refer('override'))
            ..returns = refer('String')
            ..name = 'toJson'
            ..lambda = true
            ..body = const Code('value');
        }),
        _decodeMethod(model.publicName, 'fromJson(value)'),
        _enumFromJsonMethod(model.publicName, values),
      ]);
  });
}

ExtensionType _arrayModel(FromSchemaModelSpec model) {
  final schema = model.schema;
  if (schema is! JsonArraySchema) {
    throw StateError('Expected JsonArraySchema, got $schema.');
  }

  final itemType = schema.items == null
      ? 'Object?'
      : _schemaDartType(
          schema.items!,
          nullable: schema.items!.nullable,
          refModels: model.refModels,
          typeParameters: model.typeParameters,
          source: model.source,
        );
  final publicType = _typeName(model.publicName, model.typeParameters);

  return ExtensionType((builder) {
    builder
      ..name = model.backingClassName
      ..types.addAll(_typeParameterRefs(model.typeParameters))
      ..representationDeclaration = RepresentationDeclaration(
        (builder) => builder
          ..declaredRepresentationType = refer('List<$itemType>')
          ..name = 'value',
      )
      ..implements.add(refer('List<$itemType>'))
      ..fields.addAll([
        _schemaIdField(model.schemaId),
        _schemaField(model.schema, schemaId: model.schemaId),
        _schemaRefField(),
        _requestBodyField(source: model.source, includeDecoder: true),
        _responseField(model.responseStatus),
      ])
      ..methods.addAll([
        Method((builder) {
          builder
            ..returns = refer('List<Object?>')
            ..name = 'toJson'
            ..lambda = true
            ..body = Code(
              _encodeValue(schema, 'value', nullable: false, refModels: model.refModels),
            );
        }),
        _decodeMethod(publicType, 'fromJson(value)'),
        Method((builder) {
          builder
            ..static = true
            ..returns = refer(publicType)
            ..name = 'fromJson'
            ..requiredParameters.add(_typedParameter('value', refer('Object?')))
            ..body = Code('''
return $publicType(${_decodeValue(schema, 'value', nullable: false, refModels: model.refModels, typeParameters: model.typeParameters)});
''');
        }),
      ]);
  });
}

Field _schemaIdField(String schemaId) {
  return Field((builder) {
    builder
      ..static = true
      ..modifier = FieldModifier.constant
      ..name = 'schemaId'
      ..assignment = literalString(schemaId).code;
  });
}

Field _schemaRefField() {
  return Field((builder) {
    builder
      ..static = true
      ..modifier = FieldModifier.constant
      ..name = 'schemaRef'
      ..assignment = refer('JsonSchema')
          .constInstanceNamed('componentRef', [refer('schemaId')])
          .code;
  });
}

Field _schemaField(JsonSchema schema, {required String schemaId}) {
  return Field((builder) {
    builder
      ..static = true
      ..modifier = FieldModifier.constant
      ..type = refer('JsonSchema')
      ..name = 'schema'
      ..assignment = _schemaExpression(
        schema,
        idExpression: schema.id == schemaId ? refer('schemaId') : null,
      ).code;
  });
}

Field _requestBodyField({required FromSchemaModelSource source, required bool includeDecoder}) {
  return Field((builder) {
    final constructorName = switch (source) {
      FromSchemaModelSource.json => 'json',
      FromSchemaModelSource.multipart => 'multipartFormData',
    };
    final decoderName = switch (source) {
      FromSchemaModelSource.json => 'decode',
      FromSchemaModelSource.multipart => 'decodeMultipart',
    };
    builder
      ..static = true
      ..modifier = FieldModifier.constant
      ..type = refer('RequestBody')
      ..name = 'requestBody'
      ..assignment = refer('RequestBody').constInstanceNamed(constructorName, const [], {
        'schema': refer('schema'),
        if (includeDecoder) 'decoder': refer(decoderName),
      }).code;
  });
}

Expression _schemaExpression(JsonSchema schema, {Expression? idExpression}) {
  final baseArguments = <String, Expression>{
    if (idExpression != null)
      'id': idExpression
    else if (schema.id case final id?)
      'id': literalString(id),
    if (schema.title case final title?) 'title': literalString(title),
    if (schema.description case final description?) 'description': literalString(description),
    if (schema.enumValues.isNotEmpty) 'enumValues': literalConstList(schema.enumValues),
  };

  return switch (schema) {
    JsonAnySchema() => refer('JsonSchema').constInstanceNamed('any', const [], baseArguments),
    JsonObjectSchema(
      :final nullable,
      :final properties,
      :final required,
      :final additionalProperties,
    ) =>
      refer('JsonSchema').constInstanceNamed('object', const [], {
        ...baseArguments,
        if (nullable) 'nullable': literalBool(nullable),
        if (properties.isNotEmpty)
          'properties': literalConstMap(
            {for (final entry in properties.entries) entry.key: _schemaExpression(entry.value)},
            refer('String'),
            refer('JsonSchema'),
          ),
        if (required.isNotEmpty) 'required': literalConstList(required, refer('String')),
        if (additionalProperties != null) 'additionalProperties': literalBool(additionalProperties),
      }),
    JsonArraySchema(:final nullable, :final items) => refer('JsonSchema').constInstanceNamed(
      'array',
      const [],
      {
        ...baseArguments,
        if (nullable) 'nullable': literalBool(nullable),
        if (items != null) 'items': _schemaExpression(items),
      },
    ),
    JsonAnyOfSchema(:final schemas, :final nullable, :final dartType) =>
      refer('JsonSchema').constInstanceNamed(
        'anyOf',
        [_schemaListExpression(schemas)],
        {
          ...baseArguments,
          if (nullable) 'nullable': literalBool(nullable),
          if (dartType != null) 'dartType': _dartSchemaTypeExpression(dartType),
        },
      ),
    JsonOneOfSchema(:final schemas, :final nullable, :final dartType) =>
      refer('JsonSchema').constInstanceNamed(
        'oneOf',
        [_schemaListExpression(schemas)],
        {
          ...baseArguments,
          if (nullable) 'nullable': literalBool(nullable),
          if (dartType != null) 'dartType': _dartSchemaTypeExpression(dartType),
        },
      ),
    JsonAllOfSchema(:final schemas, :final nullable, :final dartType) =>
      refer('JsonSchema').constInstanceNamed(
        'allOf',
        [_schemaListExpression(schemas)],
        {
          ...baseArguments,
          if (nullable) 'nullable': literalBool(nullable),
          if (dartType != null) 'dartType': _dartSchemaTypeExpression(dartType),
        },
      ),
    JsonStringSchema(:final nullable, :final format, :final dartType) =>
      refer('JsonSchema').constInstanceNamed('string', const [], {
        ...baseArguments,
        if (nullable) 'nullable': literalBool(nullable),
        if (format != null) 'format': literalString(format),
        if (dartType != null) 'dartType': _dartSchemaTypeExpression(dartType),
      }),
    JsonIntegerSchema(:final nullable, :final format, :final minimum, :final maximum) =>
      refer('JsonSchema').constInstanceNamed('integer', const [], {
        ...baseArguments,
        if (nullable) 'nullable': literalBool(nullable),
        if (format != null) 'format': literalString(format),
        if (minimum != null) 'minimum': literalNum(minimum),
        if (maximum != null) 'maximum': literalNum(maximum),
      }),
    JsonNumberSchema(:final nullable, :final format, :final minimum, :final maximum) =>
      refer('JsonSchema').constInstanceNamed('number', const [], {
        ...baseArguments,
        if (nullable) 'nullable': literalBool(nullable),
        if (format != null) 'format': literalString(format),
        if (minimum != null) 'minimum': literalNum(minimum),
        if (maximum != null) 'maximum': literalNum(maximum),
      }),
    JsonBooleanSchema(:final nullable) => refer('JsonSchema').constInstanceNamed(
      'boolean',
      const [],
      {...baseArguments, if (nullable) 'nullable': literalBool(nullable)},
    ),
    JsonReferenceSchema(:final ref) => refer(
      'JsonSchema',
    ).constInstanceNamed('ref', [literalString(ref)], baseArguments),
    JsonRawSchema(:final schema, :final id) => refer('JsonSchema').constInstanceNamed(
      'raw',
      [literalConstMap(schema, refer('String'), refer('Object?'))],
      {if (id != null) 'id': literalString(id)},
    ),
    _ => throw StateError('Unsupported request body schema $schema.'),
  };
}

Expression _schemaListExpression(List<JsonSchema> schemas) {
  final emitter = DartEmitter();
  final values = schemas.map((schema) => _schemaExpression(schema).accept(emitter)).join(', ');
  return CodeExpression(Code('const <JsonSchema>[$values]'));
}

Expression _dartSchemaTypeExpression(DartSchemaType dartType) {
  final typeName = _dartTypeName(dartType);
  final name = literalString(typeName ?? 'Object');
  return switch (dartType) {
    DartConcreteSchemaType(:final conversion) ||
    DartNamedSchemaType(:final conversion) => switch (conversion) {
      DartSchemaConversion.value => refer('DartSchemaType').constInstanceNamed('value', [name]),
      DartSchemaConversion.model => refer('DartSchemaType').constInstanceNamed('model', [name]),
      DartSchemaConversion.infer => refer('DartSchemaType').constInstanceNamed('named', [name]),
    },
    DartGenericSchemaType() => refer('DartSchemaType').constInstanceNamed('parameter', [name]),
  };
}

Field _responseField(int status) {
  return Field((builder) {
    builder
      ..static = true
      ..modifier = FieldModifier.constant
      ..type = refer('ResponseSpec')
      ..name = 'response'
      ..assignment = refer('ResponseSpec').constInstanceNamed('json', const [], {
        'status': literalNum(status),
        'schema': refer('schema'),
      }).code;
  });
}

Method _objectToJsonMethod(
  List<_SchemaFieldSpec> fields,
  Map<String, SchemaRefModelSpec> refModels,
) {
  return Method((builder) {
    builder
      ..annotations.add(refer('override'))
      ..returns = refer('Map<String, Object?>')
      ..name = 'toJson'
      ..body = Code('''
return <String, Object?>{
${fields.map((field) => '${_dartString(field.wireName)}: ${_encodeValue(field.schema, field.name, nullable: field.nullable, refModels: refModels)},').join('\n')}
};
''');
  });
}

Method _decodeMethod(String publicName, String expression) {
  return Method((builder) {
    builder
      ..static = true
      ..returns = refer(publicName)
      ..name = 'decode'
      ..requiredParameters.add(_typedParameter('value', refer('Object?')))
      ..body = Code('return $expression;');
  });
}

Method _objectFromJsonMethod(FromSchemaModelSpec model, List<_SchemaFieldSpec> fields) {
  final publicType = _typeName(model.publicName, model.typeParameters);
  return Method((builder) {
    builder
      ..static = true
      ..returns = refer(publicType)
      ..name = 'fromJson'
      ..requiredParameters.add(_typedParameter('json', refer('Map<String, Object?>')))
      ..body = Code('''
return $publicType(
${fields.map((field) => '${field.name}: ${_decodeValue(field.schema, "json[${_dartString(field.wireName)}]", nullable: field.nullable, refModels: model.refModels, typeParameters: model.typeParameters, path: field.name)},').join('\n')}
);
''');
  });
}

Method _objectFromMultipartMethod(FromSchemaModelSpec model, List<_SchemaFieldSpec> fields) {
  final publicType = _typeName(model.publicName, model.typeParameters);
  return Method((builder) {
    builder
      ..static = true
      ..returns = refer(publicType)
      ..name = 'decodeMultipart'
      ..requiredParameters.add(_typedParameter('form', refer('MultipartFormData')))
      ..body = Code('''
return $publicType(
${fields.map((field) => '${field.name}: ${_decodeMultipartValue(field)},').join('\n')}
);
''');
  });
}

Constructor _objectDecodeFactory(String publicType) {
  return Constructor((builder) {
    builder
      ..factory = true
      ..name = 'decode'
      ..requiredParameters.add(_typedParameter('value', refer('Object?')))
      ..body = Code('return $publicType.fromJson(readJsonObject(value));');
  });
}

Constructor _objectFromJsonFactory(FromSchemaModelSpec model, List<_SchemaFieldSpec> fields) {
  final publicType = _typeName(model.publicName, model.typeParameters);
  return Constructor((builder) {
    builder
      ..factory = true
      ..name = 'fromJson'
      ..requiredParameters.add(_typedParameter('json', refer('Map<String, Object?>')))
      ..body = Code('''
return $publicType(
${fields.map((field) => '${field.name}: ${_decodeValue(field.schema, "json[${_dartString(field.wireName)}]", nullable: field.nullable, refModels: model.refModels, typeParameters: model.typeParameters, path: field.name)},').join('\n')}
);
''');
  });
}

Method _enumFromJsonMethod(String publicName, List<_StringEnumValueSpec> values) {
  return Method((builder) {
    builder
      ..static = true
      ..returns = refer(publicName)
      ..name = 'fromJson'
      ..requiredParameters.add(_typedParameter('value', refer('Object?')))
      ..body = Code('''
return switch (value) {
${values.map((value) => '${_dartString(value.wireValue)} => $publicName.${value.name},').join('\n')}
_ => throw ArgumentError.value(value, 'value', 'Expected $publicName JSON enum value.'),
};
''');
  });
}

Parameter _typedParameter(String name, Reference type) {
  return Parameter((builder) {
    builder
      ..name = name
      ..type = type;
  });
}

List<_SchemaFieldSpec> _modelFields(FromSchemaModelSpec model) {
  final schema = model.schema;
  if (schema is! JsonObjectSchema) {
    throw StateError('Expected JsonObjectSchema, got $schema.');
  }

  final fields = <_SchemaFieldSpec>[];
  final fieldNames = <String>{};
  final required = schema.required.toSet();

  for (final entry in schema.properties.entries) {
    final fieldName = _fieldName(entry.key);
    if (!fieldNames.add(fieldName)) {
      throw InvalidGenerationSourceError(
        'Schema ${model.schemaId} contains duplicate Dart field name '
        '$fieldName.',
      );
    }

    final requiredParameter = required.contains(entry.key);
    final nullable = !requiredParameter || entry.value.nullable;
    fields.add(
      _SchemaFieldSpec(
        wireName: entry.key,
        name: fieldName,
        dartType: _schemaDartType(
          entry.value,
          nullable: nullable,
          refModels: model.refModels,
          typeParameters: model.typeParameters,
          source: model.source,
        ),
        schema: entry.value,
        requiredParameter: requiredParameter,
        nullable: nullable,
      ),
    );
  }

  return fields;
}

String _schemaDartType(
  JsonSchema schema, {
  required bool nullable,
  required Map<String, SchemaRefModelSpec> refModels,
  required List<TypeParameterSpec> typeParameters,
  required FromSchemaModelSource source,
}) {
  final type = switch (schema) {
    JsonStringSchema(:final dartType, :final format) => _stringSchemaDartType(
      dartType,
      format: format,
      typeParameters: typeParameters,
      source: source,
    ),
    JsonIntegerSchema() => 'int',
    JsonNumberSchema() => source == FromSchemaModelSource.multipart ? 'double' : 'num',
    JsonBooleanSchema() => 'bool',
    JsonArraySchema(:final items) =>
      'List<${items == null ? 'Object?' : _schemaDartType(items, nullable: items.nullable, refModels: refModels, typeParameters: typeParameters, source: source)}>',
    JsonCompositeSchema(:final dartType) =>
      _dartTypeName(dartType, typeParameters: typeParameters) ?? 'Object?',
    JsonReferenceSchema(:final ref) =>
      _refModelForReference(ref, refModels)?.typeName ?? _typeNameForSchemaRef(ref) ?? 'Object?',
    JsonObjectSchema() || JsonRawSchema() => 'Map<String, Object?>',
    JsonAnySchema() => 'Object?',
    _ => 'Object?',
  };

  if (!nullable || type.endsWith('?')) {
    return type;
  }
  return '$type?';
}

String _decodeMultipartValue(_SchemaFieldSpec field) {
  final fieldName = _dartString(field.wireName);
  return switch (field.schema) {
    JsonStringSchema(:final format) when format == 'binary' => _decodeMultipartFile(
      fieldName,
      nullable: field.nullable,
    ),
    JsonStringSchema(:final dartType) => _decodeMultipartText(
      fieldName,
      nullable: field.nullable,
      convert: (value) => _decodeMultipartStringValue(dartType, value),
    ),
    JsonIntegerSchema() => _decodeMultipartText(
      fieldName,
      nullable: field.nullable,
      convert: (value) => 'int.parse($value)',
    ),
    JsonNumberSchema() => _decodeMultipartText(
      fieldName,
      nullable: field.nullable,
      convert: (value) => 'double.parse($value)',
    ),
    JsonBooleanSchema() => _decodeMultipartText(
      fieldName,
      nullable: field.nullable,
      convert: (value) => 'bool.parse($value)',
    ),
    JsonArraySchema(:final items) when items is JsonStringSchema && items.format == 'binary' =>
      _decodeMultipartFileList(fieldName, nullable: field.nullable),
    JsonArraySchema(:final items) => _decodeMultipartTextList(
      fieldName,
      items,
      nullable: field.nullable,
    ),
    _ => throw InvalidGenerationSourceError(
      '@FromMultipartSchema only supports string, integer, number, boolean, '
      'arrays of those scalar values, and string(format: binary) file parts.',
    ),
  };
}

String _decodeMultipartFile(String fieldName, {required bool nullable}) {
  if (nullable) {
    return 'form.file($fieldName)';
  }
  return 'form.file($fieldName) ?? (throw ArgumentError.value(null, $fieldName, '
      "'Expected multipart file.'))";
}

String _decodeMultipartFileList(String fieldName, {required bool nullable}) {
  final expression =
      '(() { final values = form.filesNamed($fieldName).toList(); '
      "if (values.isEmpty) return null; return values; })()";
  if (nullable) {
    return expression;
  }
  return '(() { final values = form.filesNamed($fieldName).toList(); '
      "if (values.isEmpty) { throw ArgumentError.value(null, $fieldName, "
      "'Expected at least one multipart file.'); } return values; })()";
}

String _decodeMultipartText(
  String fieldName, {
  required bool nullable,
  required String Function(String value) convert,
}) {
  if (nullable) {
    final converted = convert('value');
    return '(() { final value = form.fieldValue($fieldName); '
        'if (value == null || value.isEmpty) return null; '
        'return $converted; })()';
  }

  final converted = convert('value');
  return '(() { final value = form.fieldValue($fieldName); '
      "if (value == null) { throw ArgumentError.value(null, $fieldName, "
      "'Expected multipart field.'); } return $converted; })()";
}

String _decodeMultipartTextList(String fieldName, JsonSchema? items, {required bool nullable}) {
  String convert(String value) {
    return switch (items) {
      null => value,
      JsonStringSchema(:final dartType) => _decodeMultipartStringValue(dartType, value),
      JsonIntegerSchema() => 'int.parse($value)',
      JsonNumberSchema() => 'double.parse($value)',
      JsonBooleanSchema() => 'bool.parse($value)',
      _ => throw InvalidGenerationSourceError(
        '@FromMultipartSchema only supports arrays of scalar text fields or '
        'binary file parts.',
      ),
    };
  }

  final converted = convert('value');
  if (nullable) {
    return '(() { final values = form.fieldValues($fieldName).toList(); '
        'if (values.isEmpty) return null; '
        'return values.map((value) => $converted).toList(); })()';
  }
  return '(() { final values = form.fieldValues($fieldName).toList(); '
      "if (values.isEmpty) { throw ArgumentError.value(null, $fieldName, "
      "'Expected multipart field.'); } "
      'return values.map((value) => $converted).toList(); })()';
}

String _decodeValue(
  JsonSchema schema,
  String source, {
  required bool nullable,
  required Map<String, SchemaRefModelSpec> refModels,
  List<TypeParameterSpec> typeParameters = const <TypeParameterSpec>[],
  String path = '',
}) {
  return switch (schema) {
    JsonStringSchema(:final dartType, :final format) => _decodeStringValue(
      dartType,
      source,
      nullable: nullable,
      format: format,
      typeParameters: typeParameters,
    ),
    JsonIntegerSchema() => nullable ? '$source as int?' : '$source! as int',
    JsonNumberSchema() => nullable ? '$source as num?' : '$source! as num',
    JsonBooleanSchema() => nullable ? '$source as bool?' : '$source! as bool',
    JsonArraySchema(:final items) => _decodeArrayValue(
      items,
      source,
      nullable: nullable,
      refModels: refModels,
      typeParameters: typeParameters,
      path: path,
    ),
    JsonCompositeSchema(:final dartType) => _decodeCompositeValue(
      dartType,
      source,
      nullable: nullable,
      typeParameters: typeParameters,
    ),
    JsonReferenceSchema(:final ref) => _decodeReferenceValue(
      ref,
      source,
      nullable: nullable,
      refModels: refModels,
      typeParameters: typeParameters,
      path: path,
    ),
    JsonObjectSchema() => _decodeObjectValue(
      schema,
      source,
      nullable: nullable,
      refModels: refModels,
      typeParameters: typeParameters,
      path: path,
    ),
    JsonRawSchema() =>
      nullable
          ? '$source == null ? null : Map<String, Object?>.from($source as Map)'
          : 'Map<String, Object?>.from($source! as Map)',
    JsonAnySchema() => source,
    _ => source,
  };
}

String _decodeArrayValue(
  JsonSchema? items,
  String source, {
  required bool nullable,
  required Map<String, SchemaRefModelSpec> refModels,
  required List<TypeParameterSpec> typeParameters,
  required String path,
}) {
  final itemExpression = items == null
      ? 'item'
      : _decodeValue(
          items,
          'item',
          nullable: items.nullable,
          refModels: refModels,
          typeParameters: typeParameters,
          path: path,
        );

  if (nullable) {
    return '($source as List?)'
        '?.map((item) => $itemExpression)'
        '.toList()';
  }

  return '($source! as List)'
      '.map((item) => $itemExpression)'
      '.toList()';
}

String _decodeReferenceValue(
  String ref,
  String source, {
  required bool nullable,
  required Map<String, SchemaRefModelSpec> refModels,
  required List<TypeParameterSpec> typeParameters,
  required String path,
}) {
  final refModel = _refModelForReference(ref, refModels);
  if (refModel != null) {
    final value = 'Map<String, Object?>.from($source! as Map)';
    if (nullable) {
      return '$source == null ? null : ${refModel.typeName}.fromJson($value)';
    }
    return '${refModel.typeName}.fromJson($value)';
  }

  final typeName = _typeNameForSchemaRef(ref);
  if (typeName == null) {
    return source;
  }

  if (nullable) {
    return '$source == null ? null : $typeName.decode($source)';
  }
  return '$typeName.decode($source)';
}

String _decodeObjectValue(
  JsonObjectSchema schema,
  String source, {
  required bool nullable,
  required Map<String, SchemaRefModelSpec> refModels,
  required List<TypeParameterSpec> typeParameters,
  required String path,
}) {
  if (schema.properties.isEmpty) {
    return nullable
        ? '$source == null ? null : Map<String, Object?>.from($source as Map)'
        : 'Map<String, Object?>.from($source! as Map)';
  }

  final mapSource = nullable
      ? 'Map<String, Object?>.from($source as Map)'
      : 'Map<String, Object?>.from($source! as Map)';
  final required = schema.required.toSet();
  final entries = schema.properties.entries
      .map((entry) {
        final fieldName = _fieldName(entry.key);
        final fieldPath = path.isEmpty ? fieldName : '$path.$fieldName';
        final fieldSource = '($mapSource)[${_dartString(entry.key)}]';
        final fieldNullable = !required.contains(entry.key) || entry.value.nullable;
        return '${_dartString(entry.key)}: ${_decodeValue(entry.value, fieldSource, nullable: fieldNullable, refModels: refModels, typeParameters: typeParameters, path: fieldPath)},';
      })
      .join('\n');
  final object = '<String, Object?>{\n$entries\n}';

  if (nullable) {
    return '$source == null ? null : $object';
  }
  return object;
}

String _decodeStringValue(
  DartSchemaType? dartType,
  String source, {
  required bool nullable,
  required String? format,
  required List<TypeParameterSpec> typeParameters,
}) {
  final stringValue = nullable ? '$source as String?' : '$source! as String';
  if (dartType == null) {
    if (format == 'date-time') {
      return nullable
          ? '$source == null ? null : DateTime.parse($source as String)'
          : 'DateTime.parse($source! as String)';
    }
    return stringValue;
  }

  if (dartType case DartConcreteSchemaType() || DartNamedSchemaType()) {
    final typeName = _dartTypeName(dartType, typeParameters: typeParameters);
    if (typeName == null) {
      return stringValue;
    }
    return switch (_dartSchemaConversion(dartType, defaultConversion: DartSchemaConversion.value)) {
      DartSchemaConversion.value =>
        nullable
            ? '$source == null ? null : $typeName($source as String)'
            : '$typeName($source! as String)',
      DartSchemaConversion.model =>
        nullable
            ? '$source == null ? null : $typeName.decode($source)'
            : '$typeName.decode($source)',
      DartSchemaConversion.infer => throw StateError(
        'Dart schema conversion inference should be resolved.',
      ),
    };
  }

  if (dartType case DartGenericSchemaType()) {
    final typeName = _dartTypeName(dartType, typeParameters: typeParameters);
    if (typeName == null) {
      return stringValue;
    }
    return nullable ? '$source as $typeName?' : '$source! as $typeName';
  }

  return stringValue;
}

String _decodeCompositeValue(
  DartSchemaType? dartType,
  String source, {
  required bool nullable,
  required List<TypeParameterSpec> typeParameters,
}) {
  final type = dartType;
  if (type == null) {
    return source;
  }
  final typeName = _dartTypeName(type, typeParameters: typeParameters);
  if (typeName == null) {
    return source;
  }
  if (type case DartGenericSchemaType()) {
    return nullable ? '$source as $typeName?' : '$source as $typeName';
  }
  return switch (_dartSchemaConversion(type, defaultConversion: DartSchemaConversion.model)) {
    DartSchemaConversion.value =>
      nullable ? '$source == null ? null : $typeName($source)' : '$typeName($source)',
    DartSchemaConversion.model =>
      nullable ? '$source == null ? null : $typeName.decode($source)' : '$typeName.decode($source)',
    DartSchemaConversion.infer => throw StateError(
      'Dart schema conversion inference should be resolved.',
    ),
  };
}

String _encodeValue(
  JsonSchema schema,
  String source, {
  required bool nullable,
  required Map<String, SchemaRefModelSpec> refModels,
}) {
  return switch (schema) {
    JsonStringSchema(:final dartType, :final format)
        when dartType == null && format == 'date-time' =>
      nullable ? '$source?.toIso8601String()' : '$source.toIso8601String()',
    JsonStringSchema(:final dartType) when dartType != null => _encodeTypedStringValue(
      dartType,
      source,
      nullable: nullable,
    ),
    JsonArraySchema(:final items) => _encodeArrayValue(
      items,
      source,
      nullable: nullable,
      refModels: refModels,
    ),
    JsonCompositeSchema(:final dartType) => _encodeCustomValue(
      dartType,
      source,
      nullable: nullable,
    ),
    JsonReferenceSchema(:final ref) => _encodeReferenceValue(
      ref,
      source,
      nullable: nullable,
      refModels: refModels,
    ),
    _ => source,
  };
}

String _decodeMultipartStringValue(DartSchemaType? dartType, String source) {
  final type = dartType;
  if (type == null || (type is! DartConcreteSchemaType && type is! DartNamedSchemaType)) {
    return source;
  }
  final typeName = _dartTypeName(type);
  if (typeName == null) {
    return source;
  }
  return switch (_dartSchemaConversion(type, defaultConversion: DartSchemaConversion.value)) {
    DartSchemaConversion.value => '$typeName($source)',
    DartSchemaConversion.model => '$typeName.decode($source)',
    DartSchemaConversion.infer => throw StateError(
      'Dart schema conversion inference should be resolved.',
    ),
  };
}

String _encodeCustomValue(DartSchemaType? dartType, String source, {required bool nullable}) {
  if (dartType == null) {
    return source;
  }
  if (dartType case DartGenericSchemaType()) {
    return source;
  }
  return switch (_dartSchemaConversion(dartType, defaultConversion: DartSchemaConversion.model)) {
    DartSchemaConversion.value => nullable ? '$source?.value' : '$source.value',
    DartSchemaConversion.model => nullable ? '$source?.toJson()' : '$source.toJson()',
    DartSchemaConversion.infer => throw StateError(
      'Dart schema conversion inference should be resolved.',
    ),
  };
}

String _encodeTypedStringValue(DartSchemaType dartType, String source, {required bool nullable}) {
  if (dartType case DartGenericSchemaType()) {
    return source;
  }
  return switch (_dartSchemaConversion(dartType, defaultConversion: DartSchemaConversion.value)) {
    DartSchemaConversion.value => nullable ? '$source?.value' : '$source.value',
    DartSchemaConversion.model => nullable ? '$source?.toJson()' : '$source.toJson()',
    DartSchemaConversion.infer => throw StateError(
      'Dart schema conversion inference should be resolved.',
    ),
  };
}

DartSchemaConversion _dartSchemaConversion(
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

String _stringSchemaDartType(
  DartSchemaType? dartType, {
  required String? format,
  required List<TypeParameterSpec> typeParameters,
  required FromSchemaModelSource source,
}) {
  if (source == FromSchemaModelSource.multipart && format == 'binary') {
    return 'MultipartFile';
  }
  return _dartTypeName(dartType, typeParameters: typeParameters) ??
      switch (format) {
        'date-time' => 'DateTime',
        _ => 'String',
      };
}

String _encodeArrayValue(
  JsonSchema? items,
  String source, {
  required bool nullable,
  required Map<String, SchemaRefModelSpec> refModels,
}) {
  final itemExpression = items == null
      ? 'item'
      : _encodeValue(items, 'item', nullable: items.nullable, refModels: refModels);
  final receiver = nullable ? '$source?' : source;
  return '$receiver.map((item) => $itemExpression).toList()';
}

String _encodeReferenceValue(
  String ref,
  String source, {
  required bool nullable,
  required Map<String, SchemaRefModelSpec> refModels,
}) {
  final typeName = _refModelForReference(ref, refModels)?.typeName ?? _typeNameForSchemaRef(ref);
  if (typeName == null) {
    return source;
  }
  return nullable ? '$source?.toJson()' : '$source.toJson()';
}

JsonSchemaRegistry _jsonSchemaRegistryFromDartObject(
  DartObject object, {
  required Element element,
}) {
  final schemas = _field(object, 'schemas')?.toListValue();
  if (schemas == null) {
    throw InvalidGenerationSourceError(
      '@FromSchema expected registry to be a const JsonSchemaRegistry.',
      element: element,
    );
  }

  return JsonSchemaRegistry(
    schemas: [for (final schema in schemas) jsonSchemaFromDartObject(schema, element: element)],
  );
}

Map<String, SchemaRefModelSpec> _schemaRefModelsFromDartObject(
  DartObject object, {
  required JsonSchemaRegistry? registry,
  required Element element,
}) {
  if (object.isNull) {
    return const <String, SchemaRefModelSpec>{};
  }

  final values = object.toListValue();
  if (values == null) {
    throw InvalidGenerationSourceError(
      '@FromSchema refs must be a const List<SchemaRefModel>.',
      element: element,
    );
  }

  final refModels = <String, SchemaRefModelSpec>{};
  for (final value in values) {
    final refModel = _schemaRefModelFromDartObject(value, registry: registry, element: element);
    if (refModels.containsKey(refModel.schemaId)) {
      throw InvalidGenerationSourceError(
        '@FromSchema refs contains duplicate schema id ${refModel.schemaId}.',
        element: element,
      );
    }
    refModels[refModel.schemaId] = refModel;
  }
  return refModels;
}

SchemaRefModelSpec _schemaRefModelFromDartObject(
  DartObject object, {
  required JsonSchemaRegistry? registry,
  required Element element,
}) {
  final type = _field(object, 'type')?.toTypeValue();
  final resolvedTypeName = type?.element?.name;
  final schemaIdOverride = _stringField(object, 'schemaId');
  final typeName = resolvedTypeName == null || resolvedTypeName.isEmpty
      ? schemaIdOverride
      : _publicSchemaRefTypeName(resolvedTypeName);
  if (typeName == null || typeName.isEmpty) {
    throw InvalidGenerationSourceError(
      '@FromSchema refs entries must be const SchemaRefModel(Type) values. '
      'Generated typedefs imported from another library must provide schemaId.',
      element: element,
    );
  }

  final schemaId = schemaIdOverride ?? typeName;
  if (schemaId.isEmpty) {
    throw InvalidGenerationSourceError(
      '@FromSchema refs entries must use non-empty schema ids.',
      element: element,
    );
  }

  if (registry != null && registry.schemaFor(schemaId) == null) {
    throw InvalidGenerationSourceError(
      'Schema ref model $typeName points to schema id $schemaId, which is not '
      'present in the supplied registry.',
      element: element,
    );
  }

  return SchemaRefModelSpec(schemaId: schemaId, typeName: typeName);
}

String _publicSchemaRefTypeName(String typeName) {
  if (typeName.startsWith(r'_$') && typeName.length > 2) {
    return typeName.substring(2);
  }
  return typeName;
}

JsonSchema _resolveRootSchema(
  JsonSchema schema, {
  required JsonSchemaRegistry? registry,
  required Element element,
}) {
  if (_supportedRootSchema(schema)) {
    return schema;
  }

  if (schema case JsonReferenceSchema(:final ref)) {
    final id = _schemaIdFromReference(ref);
    if (id == null) {
      throw InvalidGenerationSourceError(
        '@FromSchema cannot resolve external or non-component schema '
        'reference $ref.',
        element: element,
      );
    }
    final resolvedSchema = registry?.schemaFor(id);
    if (resolvedSchema == null) {
      throw InvalidGenerationSourceError(
        'Schema reference $ref is not present in the supplied registry.',
        element: element,
      );
    }
    if (_supportedRootSchema(resolvedSchema)) {
      return resolvedSchema;
    }
    throw InvalidGenerationSourceError(
      '@FromSchema resolved $ref to an unsupported schema.',
      element: element,
    );
  }

  throw InvalidGenerationSourceError(
    '@FromSchema supports object schemas, non-null array schemas, and string '
    'schemas with enumValues.',
    element: element,
  );
}

bool _supportedRootSchema(JsonSchema schema) {
  return schema is JsonObjectSchema ||
      (schema is JsonArraySchema && !schema.nullable) ||
      (schema is JsonStringSchema && schema.enumValues.isNotEmpty);
}

String _schemaIdForModel(JsonSchema sourceSchema, JsonSchema resolvedSchema, String publicName) {
  if (sourceSchema case JsonReferenceSchema(:final ref)) {
    return _schemaIdFromReference(ref) ?? sourceSchema.id ?? publicName;
  }
  return resolvedSchema.id ?? publicName;
}

void _validateSchemaReferences(JsonSchema schema, JsonSchemaRegistry registry, Element element) {
  for (final ref in _schemaRefs(schema)) {
    final id = _schemaIdFromReference(ref);
    if (id != null && registry.schemaFor(id) == null) {
      throw InvalidGenerationSourceError(
        'Schema reference $ref is not present in the supplied registry.',
        element: element,
      );
    }
  }
}

Iterable<String> _schemaRefs(JsonSchema schema) sync* {
  switch (schema) {
    case JsonObjectSchema(:final properties):
      for (final property in properties.values) {
        yield* _schemaRefs(property);
      }
    case JsonArraySchema(:final items):
      if (items != null) {
        yield* _schemaRefs(items);
      }
    case JsonCompositeSchema(:final schemas):
      for (final schema in schemas) {
        yield* _schemaRefs(schema);
      }
    case JsonReferenceSchema(:final ref):
      yield ref;
    case JsonRawSchema() || JsonAnySchema() || JsonStringSchema():
    case JsonIntegerSchema() || JsonNumberSchema() || JsonBooleanSchema():
    case _:
  }
}

List<JsonSchema> _schemaListField(DartObject object, String name, {required Element element}) {
  final values = _field(object, name)?.toListValue();
  if (values == null) {
    return const <JsonSchema>[];
  }
  return [for (final value in values) jsonSchemaFromDartObject(value, element: element)];
}

Map<String, JsonSchema> _schemaMapField(
  DartObject object,
  String name, {
  required Element element,
}) {
  final value = _field(object, name);
  final map = value?.toMapValue();
  if (map == null) {
    return const <String, JsonSchema>{};
  }

  return <String, JsonSchema>{
    for (final entry in map.entries)
      _requiredStringObject(entry.key, element: element): jsonSchemaFromDartObject(
        entry.value!,
        element: element,
      ),
  };
}

Map<String, Object?> _objectMapField(DartObject object, String name, {required Element element}) {
  final map = _field(object, name)?.toMapValue();
  if (map == null) {
    return const <String, Object?>{};
  }
  return _objectMap(map, element: element);
}

List<Object?> _objectListField(DartObject object, String name, {required Element element}) {
  final values = _field(object, name)?.toListValue();
  if (values == null) {
    return const <Object?>[];
  }
  return [for (final value in values) _objectValue(value, element: element)];
}

DartSchemaType? _dartSchemaTypeField(DartObject object, String name, {required Element element}) {
  final value = _field(object, name);
  if (value == null || value.isNull) {
    return null;
  }

  final typeName = value.type?.element?.name;
  return switch (typeName) {
    'DartConcreteSchemaType' => switch (_field(value, 'type')?.toTypeValue()) {
      final type? => DartConcreteSchemaType.named(
        type.element?.name ?? type.getDisplayString(),
        conversion: _dartSchemaConversionField(value),
      ),
      _ => throw InvalidGenerationSourceError(
        'DartSchemaType.type must be called with a Dart type.',
        element: element,
      ),
    },
    'DartNamedSchemaType' => switch (_stringField(value, 'name')) {
      final name? when name.isNotEmpty => DartSchemaType.named(
        name,
        conversion: _dartSchemaConversionField(value),
      ),
      _ => throw InvalidGenerationSourceError(
        'DartSchemaType.named must use a non-empty type name.',
        element: element,
      ),
    },
    'DartGenericSchemaType' => switch (_stringField(value, 'name')) {
      final name? when name.isNotEmpty => DartSchemaType.parameter(name),
      _ => throw InvalidGenerationSourceError(
        'DartSchemaType.parameter must use a non-empty type parameter name.',
        element: element,
      ),
    },
    _ => throw InvalidGenerationSourceError(
      'JsonSchema.string dartType must be a const DartSchemaType value.',
      element: element,
    ),
  };
}

DartSchemaConversion _dartSchemaConversionField(DartObject object) {
  final name = _field(object, 'conversion')?.getField('_name')?.toStringValue();
  return switch (name) {
    null || 'infer' => DartSchemaConversion.infer,
    'value' => DartSchemaConversion.value,
    'model' => DartSchemaConversion.model,
    _ => DartSchemaConversion.infer,
  };
}

Map<String, Object?> _objectMap(Map<DartObject?, DartObject?> map, {required Element element}) {
  return <String, Object?>{
    for (final entry in map.entries)
      _requiredStringObject(entry.key, element: element): _objectValue(
        entry.value,
        element: element,
      ),
  };
}

Object? _objectValue(DartObject? object, {required Element element}) {
  if (object == null || object.isNull) {
    return null;
  }
  if (object.toStringValue() case final value?) {
    return value;
  }
  if (object.toBoolValue() case final value?) {
    return value;
  }
  if (object.toIntValue() case final value?) {
    return value;
  }
  if (object.toDoubleValue() case final value?) {
    return value;
  }
  if (object.toListValue() case final values?) {
    return [for (final value in values) _objectValue(value, element: element)];
  }
  if (object.toMapValue() case final map?) {
    return _objectMap(map, element: element);
  }
  throw InvalidGenerationSourceError(
    'Unsupported raw JSON Schema value ${object.type}.',
    element: element,
  );
}

List<String> _stringListField(DartObject object, String name) {
  return [
    for (final value in _field(object, name)?.toListValue() ?? const <DartObject>[])
      ?value.toStringValue(),
  ];
}

String? _stringField(DartObject object, String name) {
  final value = _field(object, name);
  if (value == null || value.isNull) {
    return null;
  }
  return value.toStringValue();
}

bool? _boolField(DartObject object, String name) {
  final value = _field(object, name);
  if (value == null || value.isNull) {
    return null;
  }
  return value.toBoolValue();
}

num? _numField(DartObject object, String name) {
  final value = _field(object, name);
  if (value == null || value.isNull) {
    return null;
  }
  return value.toIntValue() ?? value.toDoubleValue();
}

DartObject? _field(DartObject object, String name) {
  final field = object.getField(name);
  if (field != null) {
    return field;
  }

  final invocation = object.constructorInvocation;
  if (invocation == null) {
    return null;
  }

  if (invocation.namedArguments[name] case final value?) {
    return value;
  }

  if ((name == 'ref' || name == 'schema' || name == 'type' || name == 'name') &&
      invocation.positionalArguments.isNotEmpty) {
    return invocation.positionalArguments.first;
  }

  return null;
}

String _requiredStringObject(DartObject? object, {required Element element}) {
  final value = object?.toStringValue();
  if (value == null) {
    throw InvalidGenerationSourceError('JSON Schema map keys must be strings.', element: element);
  }
  return value;
}

String? _typeNameForSchemaRef(String ref) {
  final id = _schemaIdFromReference(ref);
  if (id == null) {
    return null;
  }
  return _upperCamel(id);
}

SchemaRefModelSpec? _refModelForReference(String ref, Map<String, SchemaRefModelSpec> refModels) {
  final id = _schemaIdFromReference(ref);
  if (id == null) {
    return null;
  }
  return refModels[id];
}

String? _dartTypeName(
  DartSchemaType? dartType, {
  List<TypeParameterSpec> typeParameters = const <TypeParameterSpec>[],
}) {
  final typeParameterNames = _typeParameterNames(typeParameters);
  return switch (dartType) {
    DartConcreteSchemaType(:final name, :final type) => name ?? type?.toString(),
    DartNamedSchemaType(:final name) => name,
    DartGenericSchemaType(:final name) when typeParameterNames.contains(name) => name,
    DartGenericSchemaType() => null,
    null => null,
  };
}

String _typeName(String name, List<TypeParameterSpec> typeParameters) {
  if (typeParameters.isEmpty) {
    return name;
  }
  return '$name<${_typeParameterNames(typeParameters).join(', ')}>';
}

List<TypeParameterSpec> _typeParameterSpecs(TypeAliasElement element) {
  return [
    for (final parameter in element.typeParameters)
      TypeParameterSpec(name: parameter.displayName, bound: parameter.bound?.getDisplayString()),
  ];
}

List<Reference> _typeParameterRefs(List<TypeParameterSpec> typeParameters) {
  return [
    for (final parameter in typeParameters)
      refer(switch (parameter.bound) {
        final bound? => '${parameter.name} extends $bound',
        null => parameter.name,
      }),
  ];
}

Set<String> _typeParameterNames(List<TypeParameterSpec> typeParameters) {
  return {for (final parameter in typeParameters) parameter.name};
}

String? _schemaIdFromReference(String ref) {
  const componentPrefix = '#/components/schemas/';
  if (ref.startsWith(componentPrefix)) {
    return ref.substring(componentPrefix.length);
  }
  if (ref.startsWith('#') || (Uri.tryParse(ref)?.hasScheme ?? false)) {
    return null;
  }
  return ref;
}

String _fieldName(String wireName) {
  if (_validIdentifier(wireName) &&
      !_dartKeywords.contains(wireName) &&
      !wireName.startsWith('_')) {
    return wireName;
  }

  final parts = _identifierParts(wireName);
  if (parts.isEmpty) {
    return 'field';
  }

  final first = parts.first.toLowerCase();
  final rest = parts.skip(1).map(_capitalize).join();
  var name = '$first$rest';
  if (name.isEmpty || RegExp(r'^[0-9]').hasMatch(name)) {
    name = 'field${_capitalize(name)}';
  }
  if (_dartKeywords.contains(name) || name.startsWith('_')) {
    return '${name}Value';
  }
  return name;
}

List<_StringEnumValueSpec> _stringEnumValues(JsonStringSchema schema, String publicName) {
  final values = <_StringEnumValueSpec>[];
  final names = <String>{};

  for (final value in schema.enumValues) {
    if (value is! String) {
      throw InvalidGenerationSourceError(
        '@FromSchema can generate $publicName as a Dart enum only when every '
        'JsonSchema.string enumValues entry is a string.',
      );
    }

    final name = _enumValueName(value);
    if (!names.add(name)) {
      throw InvalidGenerationSourceError(
        'Schema ${schema.id ?? publicName} contains duplicate Dart enum value '
        'name $name.',
      );
    }
    values.add(_StringEnumValueSpec(name: name, wireValue: value));
  }

  return values;
}

String _enumValueName(String wireValue) {
  if (_validIdentifier(wireValue) &&
      !_dartKeywords.contains(wireValue) &&
      !wireValue.startsWith('_') &&
      !RegExp(r'^[A-Z]').hasMatch(wireValue)) {
    return wireValue;
  }

  final parts = _identifierParts(wireValue);
  var name = switch (parts) {
    [] => 'value',
    [final first, ...final rest] => '${first.toLowerCase()}${rest.map(_capitalize).join()}',
  };

  if (RegExp(r'^[0-9]').hasMatch(name)) {
    name = 'value${_capitalize(name)}';
  }
  if (_dartKeywords.contains(name) || name.startsWith('_')) {
    return '${name}Value';
  }
  return name;
}

String _upperCamel(String value) {
  if (_validIdentifier(value) &&
      !_dartKeywords.contains(value) &&
      RegExp(r'^[A-Z]').hasMatch(value)) {
    return value;
  }

  final parts = _identifierParts(value);
  if (parts.isEmpty) {
    return 'GeneratedSchema';
  }
  return parts.map(_capitalize).join();
}

List<String> _identifierParts(String value) {
  return value
      .split(RegExp(r'[^A-Za-z0-9]+'))
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
}

String _capitalize(String value) {
  if (value.isEmpty) {
    return value;
  }
  return '${value[0].toUpperCase()}${value.substring(1)}';
}

bool _validIdentifier(String value) {
  return RegExp(r'^[A-Za-z$][A-Za-z0-9$]*$').hasMatch(value);
}

String _dartString(String value) => jsonEncode(value);

final class _SchemaFieldSpec {
  const _SchemaFieldSpec({
    required this.wireName,
    required this.name,
    required this.dartType,
    required this.schema,
    required this.requiredParameter,
    required this.nullable,
  });

  final String wireName;
  final String name;
  final String dartType;
  final JsonSchema schema;
  final bool requiredParameter;
  final bool nullable;
}

final class _StringEnumValueSpec {
  const _StringEnumValueSpec({required this.name, required this.wireValue});

  final String name;
  final String wireValue;
}

final class SchemaRefModelSpec {
  const SchemaRefModelSpec({required this.schemaId, required this.typeName});

  final String schemaId;
  final String typeName;
}

final class TypeParameterSpec {
  const TypeParameterSpec({required this.name, required this.bound});

  final String name;
  final String? bound;
}

const _dartKeywords = <String>{
  'abstract',
  'as',
  'assert',
  'async',
  'await',
  'base',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'covariant',
  'default',
  'deferred',
  'do',
  'dynamic',
  'else',
  'enum',
  'export',
  'extends',
  'extension',
  'external',
  'factory',
  'false',
  'final',
  'finally',
  'for',
  'Function',
  'get',
  'hide',
  'if',
  'implements',
  'import',
  'in',
  'interface',
  'is',
  'late',
  'mixin',
  'new',
  'null',
  'on',
  'operator',
  'part',
  'required',
  'rethrow',
  'return',
  'sealed',
  'set',
  'show',
  'static',
  'super',
  'switch',
  'sync',
  'this',
  'throw',
  'true',
  'try',
  'typedef',
  'var',
  'void',
  'when',
  'while',
  'with',
  'yield',
};
