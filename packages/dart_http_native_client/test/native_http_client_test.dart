import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_http_core/dart_http_core.dart';
import 'package:dart_http_native_client/dart_http_native_client.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late NativeHttpClientTransport transport;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    transport = await NativeHttpClientTransport.open();
  });

  tearDown(() async {
    transport.close();
    await server.close(force: true);
  });

  test('sends bytes and buffers a native response', () async {
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'received': body}));
      await request.response.close();
    });

    final response = await transport.send(
      DartHttpClientRequest(
        method: HttpMethod.post,
        uri: Uri.parse('http://${server.address.host}:${server.port}/echo'),
        headers: const {'content-type': 'text/plain'},
        body: 'native request',
      ),
    );

    expect(response.status, HttpStatus.ok);
    expect(response.contentType, contains('application/json'));
    expect(jsonDecode(response.body), {'received': 'native request'});
  });

  test('streams a native response through the compatibility byte stream', () async {
    server.listen((request) async {
      request.response
        ..headers.contentType = ContentType.text
        ..write('first-');
      await request.response.flush();
      request.response.write('second');
      await request.response.close();
    });

    final response = await transport.sendStream(
      DartHttpClientRequest(
        method: HttpMethod.get,
        uri: Uri.parse('http://${server.address.host}:${server.port}/stream'),
      ),
    );
    final body = await utf8.decoder.bind(response.bodyStream).join();

    expect(response.status, HttpStatus.ok);
    expect(body, 'first-second');
  });

  test('cancels an in-flight Tokio request', () async {
    final requestStarted = Completer<void>();
    server.listen((request) async {
      requestStarted.complete();
      await Future<void>.delayed(const Duration(seconds: 5));
      await request.response.close();
    });
    final abort = Completer<void>();
    final response = transport.send(
      DartHttpClientRequest(
        method: HttpMethod.get,
        uri: Uri.parse('http://${server.address.host}:${server.port}/slow'),
        abortTrigger: abort.future,
      ),
    );
    await requestStarted.future;
    abort.complete();

    await expectLater(response, throwsA(isA<NativeHttpClientException>()));
  });
}
