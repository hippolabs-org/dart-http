import 'dart:ffi';

import 'package:dart_http_server_runtime/src/native/http_native_bridge.dart' as core_ffi;

import 'generated_bindings.dart' as gen;

final class NativeWebTransportConnection {
  const NativeWebTransportConnection({
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

final class NativeWebTransportDatagram {
  const NativeWebTransportDatagram({required this.sessionId, required this.bodyLease});

  final int sessionId;
  final core_ffi.NativeBinaryPayloadLease bodyLease;
}

final class NativeWebTransportStream {
  const NativeWebTransportStream({required this.sessionId, required this.bodyLease});

  final int sessionId;
  final core_ffi.NativeBinaryPayloadLease bodyLease;
}

final class NativeWebTransportStreamInfo {
  const NativeWebTransportStreamInfo({
    required this.sessionId,
    required this.streamId,
    required this.protocolId,
    required this.kind,
  });

  final int sessionId;
  final int streamId;
  final int protocolId;
  final int kind;
}

final class NativeWebTransportStreamChunk {
  const NativeWebTransportStreamChunk({required this.streamId, required this.bodyLease});

  final int streamId;
  final core_ffi.NativeBinaryPayloadLease bodyLease;
}

final class NativeWebTransportStreamTerminal {
  const NativeWebTransportStreamTerminal({
    required this.streamId,
    required this.errorCode,
    required this.error,
  });

  final int streamId;
  final int? errorCode;
  final String error;
}

final class NativeWebTransportOperation {
  const NativeWebTransportOperation({
    required this.operationId,
    required this.sessionId,
    required this.streamId,
    required this.protocolId,
    required this.kind,
    required this.succeeded,
    required this.error,
  });

  final int operationId;
  final int sessionId;
  final int streamId;
  final int protocolId;
  final int kind;
  final bool succeeded;
  final String error;
}

NativeWebTransportConnection decodeNativeWebTransportConnection(
  Pointer<gen.NativeWebTransportConnection> connectionPtr,
) {
  final connection = connectionPtr.ref;
  return NativeWebTransportConnection(
    sessionId: connection.session_id,
    requestId: connection.request_id,
    routeId: core_ffi.decodeNativeUtf8(connection.route_id),
    pathParams: _decodePairs(connection.path_params, connection.path_param_count),
    query: _decodePairs(connection.query, connection.query_count),
    headers: _decodePairs(connection.headers, connection.header_count),
  );
}

NativeWebTransportDatagram decodeNativeWebTransportDatagram(
  Pointer<gen.NativeWebTransportDatagram> datagramPtr, {
  required void Function() release,
}) {
  final datagram = datagramPtr.ref;
  return NativeWebTransportDatagram(
    sessionId: datagram.session_id,
    bodyLease: core_ffi.NativeBinaryPayloadLease.fromPointer(
      bytesPtr: datagram.body.ptr,
      length: datagram.body.len,
      release: release,
    ),
  );
}

NativeWebTransportStream decodeNativeWebTransportStream(
  Pointer<gen.NativeWebTransportStream> streamPtr, {
  required void Function() release,
}) {
  final stream = streamPtr.ref;
  return NativeWebTransportStream(
    sessionId: stream.session_id,
    bodyLease: core_ffi.NativeBinaryPayloadLease.fromPointer(
      bytesPtr: stream.body.ptr,
      length: stream.body.len,
      release: release,
    ),
  );
}

NativeWebTransportStreamInfo decodeNativeWebTransportStreamInfo(
  Pointer<gen.NativeWebTransportStreamInfo> infoPtr,
) {
  final info = infoPtr.ref;
  return NativeWebTransportStreamInfo(
    sessionId: info.session_id,
    streamId: info.stream_id,
    protocolId: info.protocol_id,
    kind: info.kind,
  );
}

NativeWebTransportStreamChunk decodeNativeWebTransportStreamChunk(
  Pointer<gen.NativeWebTransportStreamChunk> chunkPtr, {
  required void Function() release,
}) {
  final chunk = chunkPtr.ref;
  return NativeWebTransportStreamChunk(
    streamId: chunk.stream_id,
    bodyLease: core_ffi.NativeBinaryPayloadLease.fromPointer(
      bytesPtr: chunk.body.ptr,
      length: chunk.body.len,
      release: release,
    ),
  );
}

NativeWebTransportStreamTerminal decodeNativeWebTransportStreamTerminal(
  Pointer<gen.NativeWebTransportStreamTerminal> terminalPtr,
) {
  final terminal = terminalPtr.ref;
  return NativeWebTransportStreamTerminal(
    streamId: terminal.stream_id,
    errorCode: terminal.error_code < 0 ? null : terminal.error_code,
    error: core_ffi.decodeNativeUtf8(terminal.error),
  );
}

NativeWebTransportOperation decodeNativeWebTransportOperation(
  Pointer<gen.NativeWebTransportOperation> operationPtr,
) {
  final operation = operationPtr.ref;
  return NativeWebTransportOperation(
    operationId: operation.operation_id,
    sessionId: operation.session_id,
    streamId: operation.stream_id,
    protocolId: operation.protocol_id,
    kind: operation.kind,
    succeeded: operation.succeeded,
    error: core_ffi.decodeNativeUtf8(operation.error),
  );
}

Map<String, String> _decodePairs(Pointer<core_ffi.NativePair> pairs, int count) {
  return {for (final pair in core_ffi.copyNativePairs(pairs, count)) pair.key: pair.value};
}
