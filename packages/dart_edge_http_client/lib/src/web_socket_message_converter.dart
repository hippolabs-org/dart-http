import 'dart:typed_data';

import 'package:dart_edge_core/dart_edge_core.dart';

import 'web_socket_payload_converter.dart';

Future<WebSocketMessage> webSocketMessageFromPayload(Object? value) async {
  final blobBytes = await webSocketBlobBytes(value);
  if (blobBytes != null) {
    return WebSocketMessage.binary(blobBytes);
  }

  return switch (value) {
    final String text => WebSocketMessage.text(text),
    final List<int> bytes => WebSocketMessage.binary(bytes),
    final ByteBuffer buffer => WebSocketMessage.binary(buffer.asUint8List()),
    final ByteData data => WebSocketMessage.binary(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    ),
    null => WebSocketMessage.text(''),
    _ => throw UnsupportedError(
      'Unsupported WebSocket message payload type: ${value.runtimeType}.',
    ),
  };
}
