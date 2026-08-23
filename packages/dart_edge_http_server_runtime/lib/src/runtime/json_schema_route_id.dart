import 'package:json_schema/json_schema.dart';

/// Returns the route-level schema target only for explicit JSON Schema `$ref`s.
///
/// A schema `$id` identifies that schema but does not request lookup or
/// decoding through a registry entry.
String? jsonSchemaRouteId(JsonSchema? schema) {
  return switch (schema) {
    null => null,
    JsonReferenceSchema(:final ref) => _schemaIdFromReference(ref),
    _ => null,
  };
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
