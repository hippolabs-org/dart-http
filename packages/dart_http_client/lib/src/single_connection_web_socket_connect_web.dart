import 'package:dart_http_core/dart_http_core.dart';
import 'package:web_socket_channel/html.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

WebSocketChannel connectSingleWebSocket(
  DartHttpClientWebSocketRequest request, {
  Duration? pingInterval,
  String binaryType = 'arraybuffer',
}) {
  if (request.headers.isNotEmpty) {
    throw UnsupportedError('Browser WebSockets do not support custom HTTP headers.');
  }
  if (pingInterval != null) {
    throw UnsupportedError('Browser WebSockets do not support application-controlled pings.');
  }
  return HtmlWebSocketChannel.connect(
    request.uri,
    protocols: request.protocols,
    binaryType: binaryType == 'blob' ? BinaryType.blob : BinaryType.list,
  );
}
