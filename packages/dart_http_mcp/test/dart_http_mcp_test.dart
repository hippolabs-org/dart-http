import 'dart:convert';
import 'dart:io';

import 'package:dart_http_mcp/dart_http_mcp.dart';
import 'package:dart_http_server/dart_http_server.dart';
import 'package:dart_mcp/server.dart';
import 'package:test/test.dart';

void main() {
  late DartHttpServer server;
  late HttpClient client;

  setUp(() async {
    final app = DartHttp<void>(services: () {});
    app.mountMcp(
      '/mcp',
      serverFactory: (_) => _TestMcpServer.new,
      allowedOrigins: const <String>{},
    );
    server = await app.listen(host: '127.0.0.1', port: 0);
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.close();
  });

  test('mounts a JSON Streamable HTTP tools/list request', () async {
    final response = await _postMcp(client, server, method: 'tools/list');

    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.contentType?.mimeType, ContentType.json.mimeType);
    final body = jsonDecode(await utf8.decoder.bind(response).join()) as Map<String, Object?>;
    final result = body['result']! as Map<String, Object?>;
    final tools = result['tools']! as List<Object?>;
    expect((tools.single! as Map<String, Object?>)['name'], 'greet');
  });

  test('streams progress and a tool result over SSE', () async {
    final response = await _postMcp(
      client,
      server,
      method: 'tools/call',
      name: 'greet',
      params: <String, Object?>{
        'name': 'greet',
        'arguments': <String, Object?>{'name': 'Hippo'},
        '_meta': <String, Object?>{..._clientMeta, 'progressToken': 1},
      },
    );

    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.contentType?.mimeType, 'text/event-stream');
    final body = await utf8.decoder.bind(response).join();
    expect(body, contains('notifications/progress'));
    expect(body, contains('Hello, Hippo!'));
  });

  test('rejects an unapproved Origin', () async {
    final response = await _postMcp(
      client,
      server,
      method: 'tools/list',
      origin: 'https://untrusted.example',
    );

    expect(response.statusCode, HttpStatus.forbidden);
    expect(await response.drain<List<int>>(<int>[]), isEmpty);
  });

  test('answers non-POST methods with 405', () async {
    final request = await client.getUrl(_endpoint(server));
    final response = await request.close();

    expect(response.statusCode, HttpStatus.methodNotAllowed);
    expect(response.headers.value(HttpHeaders.allowHeader), 'POST');
  });
}

const _clientMeta = <String, Object?>{
  'io.modelcontextprotocol/protocolVersion': '2026-07-28',
  'io.modelcontextprotocol/clientInfo': <String, Object?>{
    'name': 'dart_http_mcp_test',
    'version': '0.1.0',
  },
  'io.modelcontextprotocol/clientCapabilities': <String, Object?>{},
};

Future<HttpClientResponse> _postMcp(
  HttpClient client,
  DartHttpServer server, {
  required String method,
  String? name,
  Map<String, Object?>? params,
  String? origin,
}) async {
  final request = await client.postUrl(_endpoint(server));
  request.headers
    ..contentType = ContentType.json
    ..set(HttpHeaders.acceptHeader, 'application/json, text/event-stream')
    ..set('MCP-Protocol-Version', '2026-07-28')
    ..set('Mcp-Method', method);
  if (name != null) request.headers.set('Mcp-Name', name);
  if (origin != null) request.headers.set('origin', origin);
  request.write(
    jsonEncode(<String, Object?>{
      'jsonrpc': '2.0',
      'id': 1,
      'method': method,
      'params': params ?? <String, Object?>{'_meta': _clientMeta},
    }),
  );
  return request.close();
}

Uri _endpoint(DartHttpServer server) => Uri.parse('http://${server.host}:${server.port}/mcp');

base class _TestMcpServer extends MCPServer with ToolsSupport {
  _TestMcpServer(super.channel)
    : super.fromStreamChannel(
        implementation: Implementation(name: 'dart_http_mcp_test', version: '0.1.0'),
      ) {
    registerTool(_greetTool, _greet);
  }

  static final _greetTool = Tool(
    name: 'greet',
    description: 'Greets a caller.',
    inputSchema: Schema.object(
      properties: <String, Schema>{'name': Schema.string()},
      required: const <String>['name'],
    ),
  );

  CallToolResult _greet(CallToolRequest request) {
    if (request.meta?.progressToken case final progressToken?) {
      notifyProgress(
        ProgressNotification(
          progressToken: progressToken,
          progress: 1,
          total: 1,
          message: 'Greeting',
        ),
      );
    }
    return CallToolResult(
      content: <Content>[TextContent(text: 'Hello, ${request.arguments!['name']}!')],
    );
  }
}
