import 'dart:convert';
import 'dart:io';

import 'package:dart_http_server_runtime/dart_http_server_runtime.dart';
import 'package:json_schema/json_schema.dart';
import 'package:test/test.dart';

const _querySchema = JsonSchema.object(
  id: 'ScalarQuery',
  properties: {
    'offset': JsonSchema.integer(minimum: 0, maximum: 100000),
    'ratio': JsonSchema.number(minimum: 0, maximum: 1),
    'enabled': JsonSchema.boolean(),
    'cursor': JsonSchema.string(),
    'sort': JsonSchema.string(enumValues: ['asc', 'desc']),
  },
  additionalProperties: false,
);

// This is the same core helper used by generated models' decodeQuery methods.
Map<String, Object?> _decodeQuery(Map<String, String> values) => {
  'offset': 0,
  ...decodeSchemaQueryValues(_querySchema, values),
};

void main() {
  late DartHttpServer server;
  late HttpClient client;
  var handled = 0;

  setUp(() async {
    handled = 0;
    final app = DartHttp<void>(services: () {});
    app.installSchemaRegistry(
      const JsonSchemaRegistry(
        schemas: [
          _querySchema,
          JsonSchema.integer(id: 'Offset', minimum: 0, maximum: 100000),
          JsonSchema.object(
            id: 'ReferencedQuery',
            properties: {'offset': JsonSchema.componentRef('Offset')},
            required: ['offset'],
            additionalProperties: false,
          ),
        ],
      ),
    );
    app.get(
      '/items',
      options: const RouteOptions(
        query: JsonSchema.componentRef('ScalarQuery'),
        queryDecoder: _decodeQuery,
      ),
      handler: (context) {
        handled++;
        return {
          'decoded': context.req.query<Map<String, Object?>>(),
          'raw': context.req.queryMap,
          'all': context.req.queryAllMap,
        };
      },
    );
    app.get(
      '/referenced',
      options: RouteOptions(
        query: const JsonSchema.componentRef('ReferencedQuery'),
        queryDecoder: (values) => int.parse(values['offset']!),
      ),
      handler: (context) => {'offset': context.req.query<int>()},
    );
    app.get('/raw', handler: (context) => context.req.queryMap);
    app.post(
      '/body',
      options: const RouteOptions(
        body: RequestBody.json(schema: JsonSchema.componentRef('ScalarQuery')),
      ),
      handler: (_) => {'ok': true},
    );
    app.websocket(
      '/socket',
      options: const WebSocketOptions(
        query: JsonSchema.componentRef('ScalarQuery'),
        queryDecoder: _decodeQuery,
      ),
      onConnect: (socket) async {
        handled++;
        await socket.sendJson(socket.req.query<Map<String, Object?>>());
      },
    );
    server = await app.listen(host: '127.0.0.1', port: 0);
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.close();
  });

  Future<({int status, String body})> get(String path) async {
    final response = await (await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}$path')))
        .close();
    return (status: response.statusCode, body: await utf8.decoder.bind(response).join());
  }

  test('validates typed query values before the existing decodeQuery callback', () async {
    final response = await get('/items?offset=0&ratio=0.5&enabled=false&cursor=00042&sort=asc');
    expect(response.status, 200, reason: response.body);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    expect(body['decoded'], {
      'offset': 0,
      'ratio': 0.5,
      'enabled': false,
      'cursor': '00042',
      'sort': 'asc',
    });
    expect(body['raw'], {
      'offset': '0',
      'ratio': '0.5',
      'enabled': 'false',
      'cursor': '00042',
      'sort': 'asc',
    });
    expect(handled, 1);
  });

  test('keeps omitted query defaults in the model decoder', () async {
    final response = await get('/items');
    expect(response.status, 200, reason: response.body);
    expect((jsonDecode(response.body) as Map)['decoded'], {'offset': 0});
  });

  test('preserves last-value-wins validation and all raw repeated values', () async {
    final response = await get('/items?offset=invalid&offset=50');
    expect(response.status, 200, reason: response.body);
    final body = jsonDecode(response.body) as Map;
    expect(body['decoded'], {'offset': 50});
    expect(body['all'], {
      'offset': ['invalid', '50'],
    });
  });

  test('resolves scalar component references and enforces required fields', () async {
    expect((await get('/referenced?offset=100000')).status, 200);
    expect((await get('/referenced?offset=100001')).status, 422);
    expect((await get('/referenced')).status, 422);
  });

  test('rejects malformed values, bounds, enums and unknown keys before handling', () async {
    for (final query in [
      'offset=abc',
      'offset=',
      'offset=1.5',
      'offset=-1',
      'offset=100001',
      'offset=9223372036854775808',
      'ratio=NaN',
      'ratio=Infinity',
      'ratio=1e999',
      'ratio=2',
      'enabled=yes',
      'sort=random',
      'unknown=1',
    ]) {
      final response = await get('/items?$query');
      expect(response.status, 422, reason: '$query: ${response.body}');
    }
    expect(handled, 0);
  });

  test('leaves queries without schemas and JSON body types unchanged', () async {
    final raw = await get('/raw?offset=0');
    expect(jsonDecode(raw.body), {'offset': '0'});
    final request = await client.postUrl(Uri.parse('http://127.0.0.1:${server.port}/body'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'offset': '0'}));
    final response = await request.close();
    expect(response.statusCode, 422);
    await response.drain<void>();
  });

  test('applies query conversion to WebSocket handshakes', () async {
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${server.port}/socket?offset=0&enabled=false',
    );
    try {
      expect(jsonDecode(await socket.first as String), {'offset': 0, 'enabled': false});
    } finally {
      await socket.close();
    }
    await expectLater(
      WebSocket.connect('ws://127.0.0.1:${server.port}/socket?offset=invalid'),
      throwsA(isA<WebSocketException>()),
    );
    expect(handled, 1);
  });
}
