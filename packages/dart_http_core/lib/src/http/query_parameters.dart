import 'package:json_schema/json_schema.dart';

/// Converts scalar URL query values to the JSON types declared by [schema].
///
/// The HTTP transport exposes one string per key. Array and object query values
/// need an explicit wire encoding and are not decoded by this helper.
Map<String, Object?> decodeSchemaQueryValues(JsonSchema schema, Map<String, String> values) {
  if (schema is! JsonObjectSchema) {
    throw ArgumentError.value(schema, 'schema', 'Expected an object query schema.');
  }

  final decoded = <String, Object?>{};
  for (final entry in values.entries) {
    final fieldSchema = schema.properties[entry.key];
    if (fieldSchema == null) {
      if (schema.additionalProperties == false) {
        throw FormatException('Unknown query parameter ${entry.key}.');
      }
      decoded[entry.key] = entry.value;
      continue;
    }
    decoded[entry.key] = _decodeValue(entry.key, entry.value, fieldSchema);
  }

  for (final key in schema.required) {
    if (!values.containsKey(key)) {
      throw FormatException('Missing query parameter $key.');
    }
  }
  return decoded;
}

Object _decodeValue(String key, String value, JsonSchema schema) {
  final decoded = switch (schema) {
    JsonStringSchema() => value,
    JsonIntegerSchema() => int.tryParse(value) ?? (throw FormatException('Invalid $key.')),
    JsonNumberSchema() => num.tryParse(value) ?? (throw FormatException('Invalid $key.')),
    JsonBooleanSchema() => switch (value) {
      'true' => true,
      'false' => false,
      _ => throw FormatException('Invalid $key.'),
    },
    _ => throw UnsupportedError('Query parameter $key has an unsupported schema type.'),
  };

  if (decoded is num) {
    if (!decoded.isFinite) throw FormatException('Invalid $key.');
    final minimum = switch (schema) {
      JsonIntegerSchema(:final minimum) || JsonNumberSchema(:final minimum) => minimum,
      _ => null,
    };
    final maximum = switch (schema) {
      JsonIntegerSchema(:final maximum) || JsonNumberSchema(:final maximum) => maximum,
      _ => null,
    };
    if ((minimum != null && decoded < minimum) || (maximum != null && decoded > maximum)) {
      throw FormatException('Invalid $key.');
    }
  }
  if (schema.enumValues.isNotEmpty && !schema.enumValues.contains(decoded)) {
    throw FormatException('Invalid $key.');
  }
  return decoded;
}
