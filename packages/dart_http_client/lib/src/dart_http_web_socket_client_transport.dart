import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_http_core/dart_http_core.dart';
import 'package:web_socket_client/web_socket_client.dart' as web_socket_client;

import 'web_socket_message_converter.dart';
import 'dart_http_single_connection_web_socket_transport.dart';

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

/// Portable WebSockets with one connection per connect() by default.
/// Set [reconnect] to true to opt into the legacy reconnecting transport.
final class DartHttpWebSocketClientTransport implements DartHttpClientWebSocketTransport {
  const DartHttpWebSocketClientTransport({
    this.reconnect = false,
    this.pingInterval,
    this.backoff,
    this.timeout,
    this.binaryType = 'arraybuffer',
    this._socketFactory,
  });

  final bool reconnect;
  final Duration? pingInterval;
  final web_socket_client.Backoff? backoff;
  final Duration? timeout;
  final String? binaryType;
  final DartHttpWebSocketFactory? _socketFactory;

  @override
  Future<DartHttpClientWebSocket> connect(DartHttpClientWebSocketRequest request) async {
    if (!reconnect) {
      if (backoff != null || _socketFactory != null) {
        throw ArgumentError('backoff and socketFactory require reconnect: true.');
      }
      return DartHttpSingleConnectionWebSocketClientTransport(
        connectTimeout: timeout ?? const Duration(seconds: 60),
        pingInterval: pingInterval,
        binaryType: binaryType ?? 'arraybuffer',
      ).connect(request);
    }
    final socket = (_socketFactory ?? web_socket_client.WebSocket.new)(
      request.uri,
      protocols: request.protocols,
      headers: request.headers,
      pingInterval: pingInterval,
      backoff: backoff,
      timeout: timeout,
      binaryType: binaryType,
    );
    // Subscribe before awaiting the connection state. Some servers send their
    // first protocol frame as part of the upgrade and package:web_socket_client
    // exposes messages through a broadcast stream, which otherwise drops that
    // frame while this method is still waiting for Connected.
    final client = DartHttpWebSocketClient(socket);
    try {
      await socket.connection.firstWhere(
        (state) => state is web_socket_client.Connected || state is web_socket_client.Reconnected,
      );
      return client;
    } on Object {
      await client.dispose();
      rethrow;
    }
  }
}

/// Active WebSocket connection backed by `package:web_socket_client`.
final class DartHttpWebSocketClient implements DartHttpClientWebSocket {
  DartHttpWebSocketClient(this.socket) {
    late final StreamSubscription<dynamic> subscription;
    _messages = StreamController<WebSocketMessage>(
      sync: true,
      onPause: () => subscription.pause(),
      onResume: () => subscription.resume(),
      onCancel: () => subscription.cancel(),
    );
    subscription = socket.messages
        .asyncMap(webSocketMessageFromPayload)
        .listen(_messages.add, onError: _messages.addError, onDone: _messages.close);
    _messageSubscription = subscription;
  }

  final web_socket_client.WebSocket socket;
  late final StreamController<WebSocketMessage> _messages;
  late final StreamSubscription<dynamic> _messageSubscription;

  @override
  Stream<WebSocketMessage> get messages => _messages.stream;

  @override
  Future<void> close([int? code, String? reason]) async {
    socket.close(code, reason);
  }

  Future<void> dispose() async {
    await _messageSubscription.cancel();
    socket.close();
    if (!_messages.isClosed) await _messages.close();
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
