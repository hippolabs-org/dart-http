import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_http_client/dart_http_client.dart';
import 'package:dart_http_core/dart_http_core.dart';
import 'package:test/test.dart';

void main() {
  test('one-shot transport preserves headers, protocols and immediate upgrade frames', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      expect(request.headers.value('authorization'), 'Bearer test');
      final socket = await WebSocketTransformer.upgrade(request, protocolSelector: (_) => 'test');
      socket.add('{"type":"initial"}');
      socket.listen((message) {
        if (message is String) {
          expect(jsonDecode(message), {'type': 'command'});
          socket.add([1, 2, 3]);
        }
      });
    });
    final socket = await const DartHttpWebSocketClientTransport().connect(
      DartHttpClientWebSocketRequest(
        uri: Uri.parse('ws://127.0.0.1:${server.port}/events'),
        headers: const {'authorization': 'Bearer test'},
        protocols: const ['test'],
      ),
    );
    final iterator = StreamIterator<WebSocketMessage>(socket.messages);
    addTearDown(iterator.cancel);
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current.text, '{"type":"initial"}');
    await socket.sendJson({'type': 'command'});
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current.bytes, [1, 2, 3]);
    await socket.close();
  });

  test('peer close is terminal, exposes close metadata and rejects further sends', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var connections = 0;
    server.listen((request) async {
      connections++;
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add('last');
      await socket.close(1000, 'done');
    });
    final socket = await const DartHttpWebSocketClientTransport().connect(
      DartHttpClientWebSocketRequest(uri: Uri.parse('ws://127.0.0.1:${server.port}/events')),
    );
    expect(
      (await socket.messages.toList().timeout(const Duration(seconds: 5))).single.text,
      'last',
    );
    expect(connections, 1);
    final details = (socket as DartHttpClientCloseAwareWebSocket).closeDetails!;
    expect(details.code, 1000);
    expect(details.reason, 'done');
    await expectLater(socket.sendText('next'), throwsStateError);
    await socket.close();
    await socket.close();
  });

  test('failed upgrade propagates its error and releases the channel', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.statusCode = 401;
      await request.response.close();
    });
    await expectLater(
      const DartHttpWebSocketClientTransport().connect(
        DartHttpClientWebSocketRequest(uri: Uri.parse('ws://127.0.0.1:${server.port}/events')),
      ),
      throwsException,
    );
  });

  test('connection timeout closes a late upgraded socket', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final arrived = Completer<HttpRequest>();
    server.listen(arrived.complete);
    final connecting = const DartHttpWebSocketClientTransport(timeout: Duration(milliseconds: 100))
        .connect(
          DartHttpClientWebSocketRequest(uri: Uri.parse('ws://127.0.0.1:${server.port}/events')),
        );
    final expectation = expectLater(connecting, throwsA(isA<TimeoutException>()));
    final request = await arrived.future;
    await expectation;
    final peer = await WebSocketTransformer.upgrade(request);
    await peer.drain<void>().timeout(const Duration(seconds: 5));
  });
}
