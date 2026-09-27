import 'package:dart_http_core/dart_http_core.dart';
import 'package:json_schema/json_schema.dart';
import 'package:test/test.dart';

void main() {
  const schema = JsonSchema.object(
    properties: {
      'limit': JsonSchema.integer(minimum: 1, maximum: 100),
      'ratio': JsonSchema.number(minimum: 0, maximum: 1),
      'enabled': JsonSchema.boolean(),
      'cursor': JsonSchema.string(),
      'sort': JsonSchema.string(enumValues: ['asc', 'desc']),
    },
    additionalProperties: false,
  );

  test('converts scalar query strings using schema types', () {
    expect(
      decodeSchemaQueryValues(schema, {
        'limit': '50',
        'ratio': '0.5',
        'enabled': 'false',
        'cursor': 'next-page',
      }),
      {'limit': 50, 'ratio': 0.5, 'enabled': false, 'cursor': 'next-page'},
    );
  });

  test('rejects invalid scalar values and schema constraints', () {
    for (final query in [
      {'limit': 'abc'},
      {'limit': '0'},
      {'limit': '101'},
      {'ratio': 'NaN'},
      {'enabled': 'yes'},
      {'sort': 'random'},
      {'other': 'value'},
    ]) {
      expect(() => decodeSchemaQueryValues(schema, query), throwsFormatException);
    }
  });

  test('requires fields marked required by the query schema', () {
    const requiredSchema = JsonSchema.object(
      properties: {'id': JsonSchema.string()},
      required: ['id'],
    );
    expect(() => decodeSchemaQueryValues(requiredSchema, {}), throwsFormatException);
    expect(decodeSchemaQueryValues(requiredSchema, {'id': ''}), {'id': ''});
  });
}
