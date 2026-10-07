import 'package:dart_http_core/dart_http_core.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

WebSocketChannel connectSingleWebSocket(
  DartHttpClientWebSocketRequest request, {
  Duration? pingInterval,
  String binaryType = 'arraybuffer',
}) => IOWebSocketChannel.connect(
  request.uri,
  headers: request.headers,
  protocols: request.protocols,
  pingInterval: pingInterval,
);
