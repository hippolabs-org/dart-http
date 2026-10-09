import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_http_core/dart_http_core.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'single_connection_web_socket_connect.dart'
    if (dart.library.io) 'single_connection_web_socket_connect_io.dart'
    if (dart.library.js_interop) 'single_connection_web_socket_connect_web.dart';
import 'web_socket_message_converter.dart';

/// Opens one WebSocket connection without reconnecting or replaying messages.
/// Stateful protocols recover by opening a new connection explicitly.
///
/// A request's `keepAlive` overrides [pingInterval]. `dart:io` closes the
/// connection when a ping goes unanswered until the next one, so its pong
/// timeout equals the interval. Browsers cannot send pings.
final class DartHttpSingleConnectionWebSocketClientTransport
    implements DartHttpClientWebSocketTransport {
  const DartHttpSingleConnectionWebSocketClientTransport({
    this.connectTimeout = const Duration(seconds: 60),
    this.pingInterval,
    this.binaryType = 'arraybuffer',
  });

  final Duration connectTimeout;
  final Duration? pingInterval;
  final String binaryType;

  @override
  Future<DartHttpClientWebSocket> connect(DartHttpClientWebSocketRequest request) async {
    if (connectTimeout <= Duration.zero) {
      throw ArgumentError.value(connectTimeout, 'connectTimeout', 'Must be positive.');
    }
    if (binaryType != 'arraybuffer' && binaryType != 'blob') {
      throw ArgumentError.value(binaryType, 'binaryType', 'Use arraybuffer or blob.');
    }
    request.keepAlive?.validate();
    final channel = connectSingleWebSocket(
      request,
      pingInterval: request.keepAlive?.interval ?? pingInterval,
      binaryType: binaryType,
    );
    try {
      await channel.ready.timeout(connectTimeout);
      return _SingleConnectionWebSocket(channel);
    } on Object {
      // Drain the channel's matching stream error as well as its ready failure.
      channel.stream.listen(null, onError: (Object _) {}).cancel().ignore();
      channel.sink.close().ignore();
      rethrow;
    }
  }
}

final class _SingleConnectionWebSocket implements DartHttpClientCloseAwareWebSocket {
  _SingleConnectionWebSocket(this._channel)
    : messages = _channel.stream.asyncMap(webSocketMessageFromPayload);

  final WebSocketChannel _channel;
  Future<void>? _closing;

  @override
  final Stream<WebSocketMessage> messages;

  @override
  DartHttpClientWebSocketCloseDetails? get closeDetails => _channel.closeCode == null
      ? null
      : DartHttpClientWebSocketCloseDetails(code: _channel.closeCode, reason: _channel.closeReason);

  @override
  Future<void> sendText(String value) async {
    _ensureOpen();
    _channel.sink.add(value);
  }

  @override
  Future<void> sendJson(Object? value) => sendText(jsonEncode(value));

  @override
  Future<void> sendBinary(List<int> value) async {
    _ensureOpen();
    _channel.sink.add(Uint8List.fromList(value));
  }

  @override
  Future<void> close([int? code, String? reason]) => _closing ??= _channel.sink.close(code, reason);

  void _ensureOpen() {
    if (_closing != null || _channel.closeCode != null) {
      throw StateError('WebSocket connection is closed.');
    }
  }
}
