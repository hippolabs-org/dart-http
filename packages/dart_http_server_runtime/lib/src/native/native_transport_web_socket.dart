import 'dart:ffi';
import 'dart:typed_data';

import 'package:dart_http_server_runtime/src/native/http_native_bridge.dart' as core_ffi;

import 'generated_bindings.dart' as gen;

final class NativeWebSocketConnection {
  const NativeWebSocketConnection({
    required this.sessionId,
    required this.requestId,
    required this.routeId,
    required this.pathParams,
    required this.query,
    required this.headers,
  });

  final int sessionId;
  final int requestId;
  final String routeId;
  final Map<String, String> pathParams;
  final Map<String, String> query;
  final Map<String, String> headers;
}

final class NativeWebSocketMessage {
  const NativeWebSocketMessage({
    required this.sessionId,
    required this.kind,
    this.body,
    this.bodyLease,
  });

  final int sessionId;
  final NativeWebSocketMessageKind kind;
  final Uint8List? body;
  final core_ffi.RuntimeNativeBinaryPayloadLease? bodyLease;
}

enum NativeWebSocketMessageKind { text, binary }

NativeWebSocketConnection decodeNativeWebSocketConnection(
  Pointer<gen.NativeWebSocketConnection> connectionPtr,
) {
  final connection = connectionPtr.ref;
  return NativeWebSocketConnection(
    sessionId: connection.session_id,
    requestId: connection.request_id,
    routeId: core_ffi.decodeNativeUtf8(connection.route_id),
    pathParams: _decodePairs(connection.path_params, connection.path_param_count),
    query: _decodePairs(connection.query, connection.query_count),
    headers: _decodePairs(connection.headers, connection.header_count),
  );
}

NativeWebSocketMessage decodeNativeWebSocketMessage(
  Pointer<gen.NativeWebSocketMessage> messagePtr, {
  required void Function() release,
}) {
  final message = messagePtr.ref;
  return switch (message.kind) {
    1 => NativeWebSocketMessage(
      sessionId: message.session_id,
      kind: NativeWebSocketMessageKind.text,
      body: core_ffi.maybeCopyNativeBytes(message.body) ?? Uint8List(0),
    ),
    2 => NativeWebSocketMessage(
      sessionId: message.session_id,
      kind: NativeWebSocketMessageKind.binary,
      bodyLease: core_ffi.RuntimeNativeBinaryPayloadLease.fromPointer(
        bytesPtr: message.body.ptr,
        length: message.body.len,
        release: release,
      ),
    ),
    _ => throw StateError('Unknown WebSocket message kind ${message.kind}.'),
  };
}

Map<String, String> _decodePairs(Pointer<core_ffi.NativePair> pairs, int count) {
  return {for (final pair in core_ffi.copyNativePairs(pairs, count)) pair.key: pair.value};
}
