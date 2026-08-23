import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:dart_http_server_codegen/builder.dart';
import 'package:dart_http_server_codegen/src/builder/from_schema_model_builder.dart';
import 'package:json_schema/json_schema.dart';
import 'package:test/test.dart';

void main() {
  group('generateFromSchemaModels', () {
    test('uses configured formatter page width', () {
      const model = FromSchemaModelSpec(
        publicName: 'PatientDeleteBody',
        backingClassName: r'_$PatientDeleteBody',
        schema: JsonSchema.object(
          id: 'PatientDeleteBody',
          properties: <String, JsonSchema>{
            'workspace_id': JsonSchema.string(),
            'patient_id': JsonSchema.string(),
          },
          required: <String>['workspace_id', 'patient_id'],
          additionalProperties: false,
        ),
        schemaId: 'PatientDeleteBody',
        refModels: <String, SchemaRefModelSpec>{},
        typeParameters: <TypeParameterSpec>[],
        schemasById: <String, JsonSchema>{},
        responseStatus: 200,
        source: FromSchemaModelSource.json,
      );

      final defaultOutput = generateFromSchemaModels(const [model]);
      final wideOutput = generateFromSchemaModels(const [
        model,
      ], formatterOptions: const FromSchemaFormatterOptions(pageWidth: 100));

      expect(defaultOutput, contains('static const RequestBody requestBody = RequestBody.json(\n'));
      expect(
        wideOutput,
        contains(
          'static const RequestBody requestBody = '
          'RequestBody.json(schema: schema, decoder: decode);',
        ),
      );
    });
  });

  group('dartHttpServerBuilder', () {
    test('passes formatter options from builder config', () async {
      final builder = dartHttpServerBuilder(BuilderOptions(const {'page_width': 100}));

      await testBuilder(
        builder,
        const <String, String>{
          'test_app|lib/model.dart': r'''
// ignore_for_file: undefined_class

part 'model.g.dart';

sealed class JsonSchema {
  const JsonSchema._({
    this.id,
    this.title,
    this.description,
    this.enumValues = const <Object?>[],
    this.nullable = false,
  });

  const factory JsonSchema.object({
    String? id,
    String? title,
    String? description,
    List<Object?> enumValues,
    bool nullable,
    Map<String, JsonSchema> properties,
    List<String> required,
    bool? additionalProperties,
  }) = JsonObjectSchema;

  const factory JsonSchema.string({
    String? id,
    String? title,
    String? description,
    List<Object?> enumValues,
    bool nullable,
  }) = JsonStringSchema;

  const factory JsonSchema.componentRef(
    String schemaId, {
    String? id,
    String? title,
    String? description,
    List<Object?> enumValues,
  }) = JsonReferenceSchema;

  final String? id;
  final String? title;
  final String? description;
  final List<Object?> enumValues;
  final bool nullable;
}

final class JsonObjectSchema extends JsonSchema {
  const JsonObjectSchema({
    super.id,
    super.title,
    super.description,
    super.enumValues,
    super.nullable,
    this.properties = const <String, JsonSchema>{},
    this.required = const <String>[],
    this.additionalProperties,
  }) : super._();

  final Map<String, JsonSchema> properties;
  final List<String> required;
  final bool? additionalProperties;
}

final class JsonStringSchema extends JsonSchema {
  const JsonStringSchema({
    super.id,
    super.title,
    super.description,
    super.enumValues,
    super.nullable,
  }) : super._();
}

final class JsonReferenceSchema extends JsonSchema {
  const JsonReferenceSchema.component(
    this.ref, {
    super.id,
    super.title,
    super.description,
    super.enumValues,
  }) : super._();

  final String ref;
}

final class FromHttpSchema {
  const FromHttpSchema(
    this.schema, {
    this.registry,
    this.refs = const [],
    this.responseStatus = 200,
  });

  final JsonSchema schema;
  final JsonSchemaRegistry? registry;
  final List<SchemaRefModel> refs;
  final int responseStatus;
}

final class JsonSchemaRegistry {
  const JsonSchemaRegistry(this.schemas);

  final List<JsonSchema> schemas;
}

final class SchemaRefModel {
  const SchemaRefModel(this.type, {this.schemaId});

  final Type type;
  final String? schemaId;
}

const bodySchema = JsonSchema.object(
  id: 'PatientDeleteBody',
  properties: <String, JsonSchema>{
    'workspace_id': JsonSchema.string(),
    'patient_id': JsonSchema.string(),
  },
  required: <String>['workspace_id', 'patient_id'],
  additionalProperties: false,
);

@FromHttpSchema(bodySchema)
typedef PatientDeleteBody = _$PatientDeleteBody;
''',
        },
        outputs: {
          'test_app|lib/model.dart_http_server.g.part': decodedMatches(
            contains(
              'static const RequestBody requestBody = '
              'RequestBody.json(schema: schema, decoder: decode);',
            ),
          ),
        },
      );
    });
  });
}
