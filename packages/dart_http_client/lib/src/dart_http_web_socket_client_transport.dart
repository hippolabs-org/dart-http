import 'package:dart_http_core/dart_http_core.dart';

import 'dart_http_single_connection_web_socket_transport.dart';

/// Portable WebSockets with one connection per connect().
final class DartHttpWebSocketClientTransport implements DartHttpClientWebSocketTransport {
  const DartHttpWebSocketClientTransport({
    this.pingInterval,
    this.timeout,
    this.binaryType = 'arraybuffer',
  });

  final Duration? pingInterval;
  final Duration? timeout;
  final String? binaryType;

  @override
  Future<DartHttpClientWebSocket> connect(DartHttpClientWebSocketRequest request) {
    return DartHttpSingleConnectionWebSocketClientTransport(
      connectTimeout: timeout ?? const Duration(seconds: 60),
      pingInterval: pingInterval,
      binaryType: binaryType ?? 'arraybuffer',
    ).connect(request);
  }
}
