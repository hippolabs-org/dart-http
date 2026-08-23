import 'package:json_schema/json_schema.dart';

/// Generates a Dart Edge JSON request and response model from a JSON Schema.
///
/// This is the HTTP-specific counterpart to the portable `@FromSchema`
/// annotation. [responseStatus] controls the generated `ResponseSpec`.
final class FromHttpSchema {
  const FromHttpSchema(
    this.schema, {
    this.registry,
    this.refs = const [],
    this.responseStatus = 200,
  });

  /// The schema used to infer the generated Dart model.
  final JsonSchema schema;

  /// Optional registry used for resolving schema references.
  final JsonSchemaRegistry? registry;

  /// Existing Dart model types used when this schema contains `$ref` values.
  final List<SchemaRefModel> refs;

  /// HTTP status used by the generated JSON response specification.
  final int responseStatus;
}
