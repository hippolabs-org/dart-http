import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:dart_http_core/dart_http_core.dart';
import 'package:dart_http_server_codegen/builder.dart';
import 'package:dart_http_server_codegen/dart_http_server_codegen.dart';
import 'package:dart_http_server_codegen/src/builder/from_schema_model_builder.dart';
import 'package:json_schema/json_schema.dart';
import 'package:test/test.dart';

void main() {
  test('generates a public model from a schema variable alongside a legacy alias', () async {
    await testBuilder(
      dartHttpServerBuilder(BuilderOptions.empty),
      {
        'example|lib/model.dart': r'''
part 'model.g.dart';
sealed class JsonSchema {
  const JsonSchema();
  const factory JsonSchema.object({String? id, Map<String, JsonSchema> properties, List<String> required}) = JsonObjectSchema;
  const factory JsonSchema.string() = JsonStringSchema;
  const factory JsonSchema.ref(String ref) = JsonReferenceSchema;
  const factory JsonSchema.array({JsonSchema? items}) = JsonArraySchema;
}
final class JsonObjectSchema extends JsonSchema {
  const JsonObjectSchema({this.id, this.properties = const {}, this.required = const []});
  final String? id;
  final Map<String, JsonSchema> properties;
  final List<String> required;
}
final class JsonStringSchema extends JsonSchema { const JsonStringSchema(); }
final class JsonArraySchema extends JsonSchema { const JsonArraySchema({this.items}); final JsonSchema? items; }
final class JsonReferenceSchema extends JsonSchema { const JsonReferenceSchema(this.ref); final String ref; }
class _Legacy { const _Legacy(); }
typedef Legacy = _Legacy;
enum HttpModelSource { json, multipart }
final class GenerateHttpModel {
  const GenerateHttpModel({required this.name, this.registry, this.refs = const [], this.responseStatus = 200, this.source = HttpModelSource.json});
  final String name; final Object? registry; final List<Object> refs;
  final int responseStatus; final HttpModelSource source;
}
final class FromHttpSchema {
  const FromHttpSchema(this.schema, {this.registry, this.refs = const [], this.responseStatus = 200});
  final JsonSchema schema; final Object? registry; final List<Object> refs; final int responseStatus;
}
@GenerateHttpModel(name: 'PublicBody')
const bodySchema = JsonSchema.object(id: 'Body', properties: {'value': JsonSchema.string()}, required: ['value']);
@FromHttpSchema(bodySchema)
typedef LegacyBody = _$LegacyBody;
@GenerateHttpModel(name: 'PublicWrapper')
const wrapperSchema = JsonSchema.object(properties: {'legacy': JsonSchema.ref('Legacy')}, required: ['legacy']);
@GenerateHttpModel(name: 'PublicListWrapper')
const listWrapperSchema = JsonSchema.object(properties: {'items': JsonSchema.array(items: JsonSchema.ref('Legacy'))}, required: ['items']);
''',
      },
      generateFor: {'example|lib/model.dart'},
      outputs: {
        'example|lib/model.dart_http_server.g.part': decodedMatches(
          allOf([
            contains('final class PublicBody implements JsonEncodable'),
            contains('const PublicBody({required this.value});'),
            contains("static const schemaId = 'Body';"),
            contains(r'final class _$LegacyBody'),
            isNot(contains(r'class _$PublicBody')),
            contains('const factory PublicWrapper({required Legacy legacy}) = PublicWrapper._;'),
            contains('const PublicWrapper._({required this.legacy});'),
            contains('const PublicListWrapper({required this.items});'),
            isNot(contains('factory PublicListWrapper')),
          ]),
        ),
      },
    );
  });

  test('public models construct and round-trip across libraries with dot shorthand', () async {
    final directory = await Directory.systemTemp.createTemp('http_public_models_');
    addTearDown(() => directory.delete(recursive: true));
    final source = generateFromSchemaModels([
      FromSchemaModelSpec(
        publicName: 'PublicBody',
        backingClassName: 'PublicBody',
        schema: const JsonSchema.object(
          id: 'Body',
          properties: {'value': JsonSchema.string(), 'optional': JsonSchema.string()},
          required: ['value'],
        ),
        schemaId: 'Body',
        refModels: const {},
        typeParameters: const [],
        schemasById: const {},
        responseStatus: 201,
        source: FromSchemaModelSource.json,
      ),
      const FromSchemaModelSpec(
        publicName: 'PublicWrapper',
        backingClassName: 'PublicWrapper',
        schema: JsonSchema.object(
          id: 'Wrapper',
          properties: {'legacy': JsonSchema.ref('Legacy')},
          required: ['legacy'],
        ),
        schemaId: 'Wrapper',
        refModels: {},
        typeParameters: [],
        schemasById: {},
        responseStatus: 200,
        source: FromSchemaModelSource.json,
        useFactoryConstructor: true,
      ),
    ]);
    await File('${directory.path}/legacy.dart').writeAsString('''
class _Legacy {
  const _Legacy(this.value);
  final String value;
  Map<String, Object?> toJson() => {'value': value};
  static _Legacy decode(Object? json) => _Legacy((json as Map)['value'] as String);
}
typedef Legacy = _Legacy;
Legacy readLegacy(Object? json) => _Legacy.decode(json);
''');
    await File('${directory.path}/model.dart').writeAsString('''
import 'package:dart_http_core/dart_http_core.dart';
import 'package:json_schema/json_schema.dart';
import 'legacy.dart';
$source
''');
    final clientSource = const DartHttpClientGenerator().generate(
      DartHttpClientLibrarySpec(
        className: 'PublicClient',
        additionalImports: const ['model.dart'],
        operations: [
          DartHttpClientOperation(
            method: HttpMethod.post,
            path: '/body',
            options: const RouteOptions(
              operationId: 'sendBody',
              body: RequestBody.json(schema: JsonSchema.ref('Body')),
              success: ResponseSpec.json(schema: JsonSchema.ref('Body')),
            ),
            successType: 'PublicBody',
            bodyType: 'PublicBody',
          ),
        ],
      ),
    );
    expect(clientSource, isNot(contains('class SendBodyOperation')));
    await File('${directory.path}/client.dart').writeAsString(clientSource);
    await File('${directory.path}/main.dart').writeAsString('''
import 'package:dart_http_core/dart_http_core.dart';
import 'model.dart';
import 'client.dart';
import 'legacy.dart';
PublicBody body() => .new(value: 'hello');
Future<DartHttpClientResponseObject<PublicBody>> invoke(
  DartHttpJsonBodyOperation<PublicBody, PublicBody> operation,
) => operation(body: .new(value: 'hello'));
Future<void> main() async {
  final value = PublicBody.decode(body().toJson());
  const PublicWrapper wrapped = .new(legacy: Legacy('legacy'));
  if (PublicWrapper.decode(wrapped.toJson()).legacy.value != 'legacy') throw StateError('Legacy field changed');
  if (value.value != 'hello' || value.optional != null || PublicBody.response.status != 201) {
    throw StateError('Model serialization changed');
  }
  final client = PublicClient(baseUri: Uri.parse('https://example.test'), transport: Transport());
  if ((await client.sendBody(body: .new(value: 'hello'))).requireData.value != 'hello') {
    throw StateError('Shared operation changed decoding');
  }
  final request = client.sendBody.start(body: .new(value: 'hello'));
  await request.future;
  if (request.state != DartHttpClientRequestState.succeeded || client.sendBody.info.pathTemplate != '/body') {
    throw StateError('Shared operation changed lifecycle or metadata');
  }
  print('ok');
}
class Transport implements HttpClientTransport {
  Future<DartHttpClientResponse> send(DartHttpClientRequest request) async =>
    const DartHttpClientResponse(status: 200, contentType: 'application/json', body: '{"value":"hello"}');
  Future<DartHttpClientStreamedResponse> sendStream(DartHttpClientRequest request) => throw UnsupportedError('buffered only');
}
''');
    final result = await Process.run(Platform.resolvedExecutable, [
      '--packages=${(await Isolate.packageConfig)!.toFilePath()}',
      '${directory.path}/main.dart',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('ok'));

    final packageConfigUri = (await Isolate.packageConfig)!;
    final config =
        jsonDecode(await File.fromUri(packageConfigUri).readAsString()) as Map<String, dynamic>;
    for (final package in config['packages'] as List<dynamic>) {
      final entry = package as Map<String, dynamic>;
      entry['rootUri'] = packageConfigUri.resolve(entry['rootUri'] as String).toString();
    }
    await Directory('${directory.path}/.dart_tool').create();
    await File('${directory.path}/.dart_tool/package_config.json')
        .writeAsString(jsonEncode(config));
    await File('${directory.path}/analysis_options.yaml').writeAsString('''
linter:
  rules:
    library_private_types_in_public_api: true
    type_init_formals: true
    prefer_initializing_formals: true
''');
    final analyzed = await Process.run(Platform.resolvedExecutable, [
      'analyze',
      '--fatal-infos',
      directory.path,
    ]);
    expect(analyzed.exitCode, 0, reason: '${analyzed.stdout}\n${analyzed.stderr}');

    await File('${directory.path}/invalid.dart').writeAsString('''
import 'client.dart';
void invalid(PublicClient client) {
  client.sendBody();
  client.sendBody.stream();
}
void main() {}
''');
    final invalid = await Process.run(Platform.resolvedExecutable, [
      '--packages=${(await Isolate.packageConfig)!.toFilePath()}',
      '${directory.path}/invalid.dart',
    ]);
    expect(invalid.exitCode, isNot(0));
    expect(invalid.stderr, contains("Required named parameter 'body' must be provided"));
    expect(invalid.stderr, contains("The method 'stream' isn't defined"));
  });

  test(
    'shared JSON model emitter preserves inline identities and raw reference bindings',
    () async {
      const child = JsonSchema.object(
        id: 'ChildPayload',
        properties: {'value': JsonSchema.string()},
        required: ['value'],
      );
      const envelope = JsonSchema.object(
        id: 'Envelope',
        properties: {'child': child, 'raw_id': JsonSchema.ref('RawId')},
        required: ['child', 'raw_id'],
      );
      final generated = const DartHttpClientGenerator().generate(
        DartHttpClientLibrarySpec(
          className: 'EnvelopeClient',
          schemas: const [envelope, child],
          schemaTypes: const {'RawId': 'String'},
          operations: [
            DartHttpClientOperation(
              method: HttpMethod.post,
              path: '/envelope',
              options: const RouteOptions(
                operationId: 'sendEnvelope',
                body: RequestBody.json(schema: JsonSchema.ref('Envelope')),
                success: ResponseSpec.json(schema: JsonSchema.ref('Envelope')),
              ),
              bodyType: 'Envelope',
              successType: 'Envelope',
            ),
          ],
        ),
      );
      final directory = await Directory.systemTemp.createTemp('http_client_models_');
      addTearDown(() => directory.delete(recursive: true));
      await File('${directory.path}/client.dart').writeAsString(generated);
      await File('${directory.path}/main.dart').writeAsString('''
import 'client.dart';
void main() {
  final value = Envelope.decode({'child': {'value': 'nested'}, 'raw_id': 'raw'});
  final ChildPayload child = value.child;
  if (child.value != 'nested' || value.rawId != 'raw' ||
      (value.toJson()['child'] as Map)['value'] != 'nested' || value.toJson()['raw_id'] != 'raw') {
    throw StateError('Model mapping changed');
  }
}
''');
      final result = await Process.run(Platform.resolvedExecutable, [
        '--packages=${(await Isolate.packageConfig)!.toFilePath()}',
        '${directory.path}/main.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
  );
}
