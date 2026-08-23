import 'dart:convert';
import 'dart:typed_data';

import '../transport/binary_payload_lease.dart';

/// The frame kind for a WebSocket message.
enum WebSocketMessageKind { text, binary }

/// One incoming or outgoing WebSocket data frame.
final class WebSocketMessage {
  WebSocketMessage._({required this.kind, this._bytes, this._binaryLease});

  /// Creates a text frame from a Dart string.
  factory WebSocketMessage.text(String value) {
    return WebSocketMessage._(
      kind: WebSocketMessageKind.text,
      bytes: Uint8List.fromList(utf8.encode(value)),
    );
  }

  /// Creates a binary frame from raw bytes.
  factory WebSocketMessage.binary(List<int> value) {
    return WebSocketMessage._(kind: WebSocketMessageKind.binary, bytes: Uint8List.fromList(value));
  }

  /// Creates a binary frame that owns [lease] until copied, transferred, or
  /// closed.
  factory WebSocketMessage.leasedBinary(BinaryPayloadLease lease) {
    return WebSocketMessage._(kind: WebSocketMessageKind.binary, binaryLease: lease);
  }

  /// Whether this is a text or binary frame.
  final WebSocketMessageKind kind;

  Uint8List? _bytes;
  BinaryPayloadLease? _binaryLease;

  /// Raw frame bytes.
  ///
  /// A native leased payload is copied lazily on first access and its native
  /// owner is then released. Use [takeBinaryLease] to avoid that copy.
  Uint8List get bytes {
    final bytes = _bytes;
    if (bytes != null) return bytes;
    final lease = _binaryLease;
    if (lease == null) {
      throw StateError('WebSocket binary payload has been transferred.');
    }
    final copied = lease.takeBytes();
    _binaryLease = null;
    _bytes = copied;
    return copied;
  }

  bool get hasBinaryLease => _binaryLease != null;

  /// Transfers ownership of this binary frame without copying its payload.
  BinaryPayloadLease takeBinaryLease() {
    if (kind != WebSocketMessageKind.binary) {
      throw StateError('Only binary WebSocket frames have payload leases.');
    }
    final lease = _binaryLease;
    if (lease != null) {
      _binaryLease = null;
      return lease;
    }
    final bytes = _bytes;
    if (bytes == null) {
      throw StateError('WebSocket binary payload has already been transferred.');
    }
    _bytes = null;
    return BinaryPayloadLease.fromBytes(bytes);
  }

  /// Releases a leased binary payload without copying it.
  void close() {
    _binaryLease?.close();
    _binaryLease = null;
  }

  /// Decodes this frame as UTF-8 text.
  String get text => utf8.decode(bytes);
}
