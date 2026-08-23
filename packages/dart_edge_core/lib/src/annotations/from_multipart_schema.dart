import 'package:json_schema/json_schema.dart';

/// Generates a Dart request-body model from a multipart form-data schema.
///
/// Use `JsonSchema.string(format: 'binary')` for uploaded file parts.
final class FromMultipartSchema {
  const FromMultipartSchema(this.schema, {this.registry, this.refs = const []});

  /// The schema used to infer the generated Dart model.
  final JsonSchema schema;

  /// Optional registry used for resolving schema references.
  final JsonSchemaRegistry? registry;

  /// Existing Dart model types used when this schema contains `$ref` values.
  final List<SchemaRefModel> refs;
}
