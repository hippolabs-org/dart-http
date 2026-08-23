import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../transport/binary_payload_lease.dart';
import 'web_socket_message.dart';

/// Accessor for incoming WebSocket messages exposed to a socket handler.
final class IncomingWebSocketMessages {
  const IncomingWebSocketMessages([Stream<WebSocketMessage>? messages])
    : _messages = messages ?? const Stream<WebSocketMessage>.empty();

  final Stream<WebSocketMessage> _messages;

  /// Returns all incoming data frames.
  ///
  /// For a leased binary frame, either read [WebSocketMessage.bytes] to copy
  /// and release it or transfer ownership with
  /// [WebSocketMessage.takeBinaryLease].
  Stream<WebSocketMessage> frames() => _messages;

  /// Returns the incoming message stream as raw UTF-8 text frames.
  Stream<String> text() {
    return _messages.asyncExpand((message) {
      if (message.kind == WebSocketMessageKind.text) {
        return Stream<String>.value(message.text);
      }
      message.close();
      return const Stream<String>.empty();
    });
  }

  /// Returns the incoming message stream as raw binary frames.
  Stream<Uint8List> binary() {
    return _messages
        .where((message) => message.kind == WebSocketMessageKind.binary)
        .map((message) => message.bytes);
  }

  /// Returns binary frames as single-owner payload leases.
  ///
  /// Consumers must close each lease, normally with `try/finally`. A native
  /// runtime can serve these without allocating or copying Dart-managed bytes.
  Stream<BinaryPayloadLease> leasedBinary() {
    return _messages
        .where((message) => message.kind == WebSocketMessageKind.binary)
        .map((message) => message.takeBinaryLease());
  }

  /// Returns the incoming message stream decoded as JSON values of type [T].
  Stream<T> json<T>() {
    return text().map<T>((message) {
      final decoded = jsonDecode(message);
      if (decoded is T) {
        return decoded;
      }

      throw StateError('Incoming WebSocket message is ${decoded.runtimeType}, not $T.');
    });
  }
}
