import 'package:dart_http_server/dart_http_server.dart';
import 'package:json_schema/json_schema.dart';
import 'package:test/test.dart';

void main() {
  test('exports Dart HTTP schema annotations from the app-facing package', () {
    const schema = JsonSchema.object(id: 'ExportedAnnotationModel');
    const annotation = FromHttpSchema(
      schema,
      refs: <SchemaRefModel>[SchemaRefModel(_ReferencedModel)],
    );

    expect(annotation.schema, same(schema));
    expect(annotation.refs.single.type, _ReferencedModel);
  });
}

final class _ReferencedModel {}
