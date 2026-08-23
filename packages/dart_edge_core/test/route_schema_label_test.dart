import 'package:dart_edge_core/dart_edge_core.dart';
import 'package:json_schema/json_schema.dart';
import 'package:test/test.dart';

void main() {
  test('reads decoded JSON objects as string-keyed maps', () {
    final value = readJsonObject(<Object?, Object?>{'id': '42'});

    expect(value, {'id': '42'});
    expect(readJsonObject(value), same(value));
  });

  test('route option labels use refs, not inline ids, as schema targets', () {
    final inline = RouteOptions(
      operationId: 'inline',
      body: RequestBody.json(schema: const JsonSchema.object(id: 'UserDto')),
      success: ResponseSpec.json(),
    ).toString();
    final referenced = RouteOptions(
      operationId: 'referenced',
      body: RequestBody.json(schema: const JsonSchema.ref('UserDto')),
      success: ResponseSpec.json(),
    ).toString();

    expect(inline, isNot(contains('<UserDto>')));
    expect(referenced, contains('application/json; charset=utf-8<UserDto>'));
  });
}
