import 'package:json_schema/json_schema.dart';

/// Request decoding used by a generated public HTTP model.
enum HttpModelSource { json, multipart }

/// Generates a public model from the annotated const [JsonSchema] variable.
///
/// Unlike `FromHttpSchema`, no typedef or private backing class is needed.
final class GenerateHttpModel {
  const GenerateHttpModel({
    required this.name,
    this.registry,
    this.refs = const [],
    this.responseStatus = 200,
    this.source = HttpModelSource.json,
  });

  /// Public Dart type name, independent of the schema's identifier.
  final String name;
  final JsonSchemaRegistry? registry;
  final List<SchemaRefModel> refs;
  final int responseStatus;
  final HttpModelSource source;
}
