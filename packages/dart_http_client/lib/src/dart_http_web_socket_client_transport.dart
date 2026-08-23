import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_http_core/dart_http_core.dart';
import 'package:web_socket_client/web_socket_client.dart' as web_socket_client;

import 'web_socket_message_converter.dart';

/// Creates `web_socket_client` sockets for generated Dart HTTP clients.
typedef DartHttpWebSocketFactory = web_socket_client.WebSocket Function(
  Uri uri, {
  Iterable<String>? protocols,
  Duration? pingInterval,
  Map<String, dynamic>? headers,
  web_socket_client.Backoff? backoff,
  Duration? timeout,
  String? binaryType,
});

/// WebSocket transport backed by `package:web_socket_client`.
final class DartHttpWebSocketClientTransport implements DartHttpClientWebSocketTransport {
  const DartHttpWebSocketClientTransport({
    this.pingInterval,
    this.backoff,
    this.timeout,
    this.binaryType = 'arraybuffer',
    DartHttpWebSocketFactory? socketFactory,
  }) : _socketFactory = socketFactory ?? web_socket_client.WebSocket.new;

  final Duration? pingInterval;
  final web_socket_client.Backoff? backoff;
  final Duration? timeout;
  final String? binaryType;
  final DartHttpWebSocketFactory _socketFactory;

  @override
  Future<DartHttpClientWebSocket> connect(DartHttpClientWebSocketRequest request) async {
    final socket = _socketFactory(
      request.uri,
      protocols: request.protocols,
      headers: request.headers,
      pingInterval: pingInterval,
      backoff: backoff,
      timeout: timeout,
      binaryType: binaryType,
    );
    await socket.connection.firstWhere(
      (state) => state is web_socket_client.Connected || state is web_socket_client.Reconnected,
    );
    return DartHttpWebSocketClient(socket);
  }
}

/// Active WebSocket connection backed by `package:web_socket_client`.
final class DartHttpWebSocketClient implements DartHttpClientWebSocket {
  const DartHttpWebSocketClient(this.socket);

  final web_socket_client.WebSocket socket;

  @override
  Stream<WebSocketMessage> get messages => socket.messages.asyncMap(webSocketMessageFromPayload);

  @override
  Future<void> close([int? code, String? reason]) async {
    socket.close(code, reason);
  }

  @override
  Future<void> sendBinary(List<int> value) async {
    socket.send(Uint8List.fromList(value));
  }

  @override
  Future<void> sendJson(Object? value) async {
    socket.send(jsonEncode(value));
  }

  @override
  Future<void> sendText(String value) async {
    socket.send(value);
  }
}
