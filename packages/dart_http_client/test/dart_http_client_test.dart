import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_http_core/dart_http_core.dart';
import 'package:dart_http_client/dart_http_client.dart';
import 'package:dart_http_client/src/web_socket_message_converter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('DartHttpClientTransport', () {
    test('sends requests through package:http and applies interceptors', () async {
      final transport = DartHttpClientTransport(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url, Uri.parse('https://api.example.test/hello'));
          expect(request.headers['authorization'], 'Bearer test-token');
          return http.Response('ok', 200, headers: {'content-type': 'text/plain; charset=utf-8'});
        }),
        interceptors: [DartHttpBearerTokenInterceptor(() async => 'test-token').call],
      );

      final response = await transport.send(
        DartHttpClientRequest(
          method: HttpMethod.get,
          uri: Uri.parse('https://api.example.test/hello'),
        ),
      );

      expect(response.status, 200);
      expect(response.contentType, 'text/plain; charset=utf-8');
      expect(response.body, 'ok');
      expect(response.bodyBytes, utf8.encode('ok'));
    });

    test('sends request body bytes through package:http', () async {
      final transport = DartHttpClientTransport(
        client: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.headers['content-type'], 'multipart/form-data');
          expect(request.bodyBytes, [1, 2, 3]);
          return http.Response('', 204);
        }),
      );

      final response = await transport.send(
        DartHttpClientRequest(
          method: HttpMethod.post,
          uri: Uri.parse('https://api.example.test/uploads'),
          headers: const {'content-type': 'multipart/form-data'},
          bodyBytes: const [1, 2, 3],
        ),
      );

      expect(response.status, 204);
    });

    test('consumes leased request bytes through package:http', () async {
      final lease = DartByteLease(Uint8List.fromList([3, 1, 4]));
      final transport = DartHttpClientTransport(
        client: MockClient((request) async {
          expect(request.bodyBytes, [3, 1, 4]);
          return http.Response('', 204);
        }),
      );

      await transport.send(
        DartHttpClientRequest(
          method: HttpMethod.post,
          uri: Uri.parse('https://api.example.test/leased'),
          bodyLease: lease,
        ),
      );

      expect(lease.isClosed, isTrue);
    });

    test('sends request body streams through package:http', () async {
      final transport = DartHttpClientTransport(
        client: MockClient.streaming((request, bodyStream) async {
          expect(request.method, 'POST');
          expect(request.headers['content-type'], 'multipart/form-data');
          expect(request.contentLength, isNull);
          expect(await bodyStream.toBytes(), [1, 2, 3]);
          return http.StreamedResponse(const Stream<List<int>>.empty(), 204);
        }),
      );

      final response = await transport.send(
        DartHttpClientRequest(
          method: HttpMethod.post,
          uri: Uri.parse('https://api.example.test/uploads'),
          headers: const {'content-type': 'multipart/form-data'},
          bodyStream: Stream.fromIterable(const [
            [1],
            [2, 3],
          ]),
        ),
      );

      expect(response.status, 204);
    });

    test('sets streamed request content length when known', () async {
      final transport = DartHttpClientTransport(
        client: MockClient.streaming((request, bodyStream) async {
          expect(request.contentLength, 3);
          expect(await bodyStream.toBytes(), [1, 2, 3]);
          return http.StreamedResponse(const Stream<List<int>>.empty(), 204);
        }),
      );

      final response = await transport.send(
        DartHttpClientRequest(
          method: HttpMethod.post,
          uri: Uri.parse('https://api.example.test/uploads'),
          bodyStream: Stream.value(const [1, 2, 3]),
          bodyStreamLength: 3,
        ),
      );

      expect(response.status, 204);
    });

    test('uses abortable requests when no abort trigger is supplied', () async {
      final transport = DartHttpClientTransport(
        client: MockClient.streaming((request, _) async {
          expect(request, isA<http.AbortableRequest>());
          expect((request as http.AbortableRequest).abortTrigger, isNull);
          return http.StreamedResponse(const Stream<List<int>>.empty(), 204);
        }),
      );

      final response = await transport.send(
        DartHttpClientRequest(
          method: HttpMethod.get,
          uri: Uri.parse('https://api.example.test/jobs'),
        ),
      );

      expect(response.status, 204);
    });

    test('passes abort triggers through to package:http', () async {
      final abortCompleter = Completer<void>();
      final transport = DartHttpClientTransport(
        client: MockClient.streaming((request, _) async {
          expect(request, isA<http.AbortableRequest>());
          expect((request as http.AbortableRequest).abortTrigger, same(abortCompleter.future));
          return http.StreamedResponse(const Stream<List<int>>.empty(), 204);
        }),
      );

      final response = await transport.send(
        DartHttpClientRequest(
          method: HttpMethod.delete,
          uri: Uri.parse('https://api.example.test/jobs/1'),
          abortTrigger: abortCompleter.future,
        ),
      );

      expect(response.status, 204);
    });

    test('returns streamed responses without buffering the body', () async {
      var listened = false;
      final transport = DartHttpClientTransport(
        client: MockClient.streaming((request, _) async {
          expect(request.method, 'GET');
          return http.StreamedResponse(
            Stream<List<int>>.fromIterable([utf8.encode('data: alpha\n\n')]).map((chunk) {
              listened = true;
              return chunk;
            }),
            200,
            headers: {'content-type': 'text/event-stream; charset=utf-8'},
          );
        }),
      );

      final response = await transport.sendStream(
        DartHttpClientRequest(
          method: HttpMethod.get,
          uri: Uri.parse('https://api.example.test/events'),
        ),
      );

      expect(response.status, 200);
      expect(response.contentType, 'text/event-stream; charset=utf-8');
      expect(listened, isFalse);
      expect(
        utf8.decode(await response.bodyStream.expand((chunk) => chunk).toList()),
        'data: alpha\n\n',
      );
      expect(listened, isTrue);
    });

    test('uses SSE-safe request headers for server-sent event streams', () async {
      final transport = DartHttpClientTransport(
        client: MockClient.streaming((request, _) async {
          expect(request.headers['accept'], 'text/event-stream');
          expect(request.headers['accept-encoding'], 'identity');
          return http.StreamedResponse(const Stream<List<int>>.empty(), 200);
        }),
      );

      await transport.sendStream(
        DartHttpClientRequest(
          method: HttpMethod.get,
          uri: Uri.parse('https://api.example.test/events'),
          headers: const {'Accept': 'application/json', 'Accept-Encoding': 'gzip'},
          responseMode: DartHttpClientResponseMode.serverSentEvents,
        ),
      );
    });

    test('applies streamed interceptors to streamed responses', () async {
      final bearer = DartHttpBearerTokenInterceptor(() async => 'test-token');
      final transport = DartHttpClientTransport(
        client: MockClient.streaming((request, _) async {
          expect(request.headers['authorization'], 'Bearer test-token');
          return http.StreamedResponse(const Stream<List<int>>.empty(), 204);
        }),
        streamedInterceptors: [bearer.stream],
      );

      final response = await transport.sendStream(
        DartHttpClientRequest(
          method: HttpMethod.get,
          uri: Uri.parse('https://api.example.test/events'),
        ),
      );

      expect(response.status, 204);
    });
  });

  group('DartHttpWebSocketClientTransport', () {
    test('connects through web_socket_client and maps messages', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((message) {
          socket.add(message);
        });
      });

      final transport = DartHttpWebSocketClientTransport(
        backoff: const ConstantBackoff(Duration.zero),
      );
      final socket = await transport.connect(
        DartHttpClientWebSocketRequest(
          uri: Uri.parse('ws://${server.address.host}:${server.port}/socket'),
        ),
      );
      addTearDown(() => socket.close());

      final echo = Completer<WebSocketMessage>();
      final subscription = socket.messages.listen((message) {
        if (!echo.isCompleted) {
          echo.complete(message);
        }
      });
      addTearDown(subscription.cancel);

      await socket.sendJson({'ok': true});
      final second = await echo.future.timeout(const Duration(seconds: 5));
      expect(second.kind, WebSocketMessageKind.text);
      expect(jsonDecode(second.text), {'ok': true});
    });

    test('buffers a server frame sent before the first listener attaches', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add('session.created');
      });

      final transport = DartHttpWebSocketClientTransport(
        backoff: const ConstantBackoff(Duration.zero),
      );
      final socket = await transport.connect(
        DartHttpClientWebSocketRequest(
          uri: Uri.parse('ws://${server.address.host}:${server.port}/immediate'),
        ),
      );
      addTearDown(socket.close);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        (await socket.messages.first.timeout(const Duration(seconds: 5))).text,
        'session.created',
      );
    });

    test('maps typed binary payloads to binary messages', () async {
      final fromBytes = await webSocketMessageFromPayload(<int>[1, 2, 3]);
      expect(fromBytes.kind, WebSocketMessageKind.binary);
      expect(fromBytes.bytes, [1, 2, 3]);

      final byteData = ByteData(3)
        ..setUint8(0, 4)
        ..setUint8(1, 5)
        ..setUint8(2, 6);
      final fromByteData = await webSocketMessageFromPayload(byteData);
      expect(fromByteData.kind, WebSocketMessageKind.binary);
      expect(fromByteData.bytes, [4, 5, 6]);
    });

    test('rejects unsupported payloads instead of stringifying them', () {
      expect(webSocketMessageFromPayload(Object()), throwsA(isA<UnsupportedError>()));
    });
  });
}
