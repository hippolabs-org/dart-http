import 'dart:typed_data';

import '../context/request_context.dart';
import '../context/request_input.dart';
import '../context/request_telemetry.dart';
import '../transport/binary_payload_lease.dart';
import 'incoming_web_socket_messages.dart';
import 'web_socket_message.dart';

typedef WebSocketTextSender = Future<void> Function(String value);
typedef WebSocketBinarySender = Future<void> Function(List<int> value);
typedef WebSocketBinaryLeaseSender = Future<void> Function(BinaryPayloadLease lease);
typedef WebSocketJsonSender = Future<void> Function(Object? value);
typedef WebSocketCloser = Future<void> Function([int? code, String? reason]);

/// Context passed to a WebSocket route when a client connects.
final class WebSocketContext<TServices> {
  WebSocketContext({
    required this.services,
    this.req = RequestInput.empty,
    this.messages = const IncomingWebSocketMessages(),
    this.telemetry = const RequestTelemetry(),
    this._sendText,
    this._sendBinary,
    this._sendBinaryLease,
    this._sendJson,
    this._close,
  }) : _requestContext = RequestContext<TServices>(
         services: services,
         req: req,
         telemetry: telemetry,
       );

  WebSocketContext.fromRequest({
    required RequestContext<TServices> request,
    this.messages = const IncomingWebSocketMessages(),
    this._sendText,
    this._sendBinary,
    this._sendBinaryLease,
    this._sendJson,
    this._close,
  }) : services = request.services,
       req = request.req,
       telemetry = request.telemetry,
       _requestContext = request;

  /// Fresh services instance for the socket connection.
  final TServices services;

  /// Decoded request params, query, and headers for the handshake request.
  final RequestInput req;

  /// Incoming messages exposed as typed streams.
  final IncomingWebSocketMessages messages;

  /// Telemetry hook associated with the socket lifecycle.
  final RequestTelemetry telemetry;

  final RequestContext<TServices> _requestContext;
  final WebSocketTextSender? _sendText;
  final WebSocketBinarySender? _sendBinary;
  final WebSocketBinaryLeaseSender? _sendBinaryLease;
  final WebSocketJsonSender? _sendJson;
  final WebSocketCloser? _close;

  /// Shared request-scoped context used during guard evaluation.
  RequestContext<TServices> get request => _requestContext;

  /// Reads a required request-scoped extension of type [T].
  T require<T>() => _requestContext.require<T>();

  /// Reads an optional request-scoped extension of type [T].
  T? maybe<T>() => _requestContext.maybe<T>();

  /// Stores a request-scoped extension by its runtime type.
  void put<T>(T value) {
    _requestContext.put<T>(value);
  }

  /// Sends one text frame to the client.
  Future<void> sendText(String value) async {
    final sendText = _sendText;
    if (sendText == null) {
      return;
    }
    await sendText(value);
  }

  /// Sends one binary frame to the client.
  Future<void> sendBinary(List<int> value) async {
    final sendBinary = _sendBinary;
    if (sendBinary == null) {
      return;
    }
    await sendBinary(Uint8List.fromList(value));
  }

  /// Sends and consumes one single-owner binary payload.
  ///
  /// Native runtimes can borrow a native lease directly. The lease is always
  /// closed after the send operation completes or fails.
  Future<void> sendBinaryLease(BinaryPayloadLease lease) async {
    try {
      final sendBinaryLease = _sendBinaryLease;
      if (sendBinaryLease != null) {
        await sendBinaryLease(lease);
        return;
      }
      await sendBinary(lease.bytesView);
    } finally {
      lease.close();
    }
  }

  /// Sends one text or binary frame to the client.
  Future<void> sendFrame(WebSocketMessage message) async {
    switch (message.kind) {
      case WebSocketMessageKind.text:
        await sendText(message.text);
      case WebSocketMessageKind.binary:
        if (message.hasBinaryLease) {
          await sendBinaryLease(message.takeBinaryLease());
        } else {
          await sendBinary(message.bytes);
        }
    }
  }

  /// Sends a JSON value to the client.
  Future<void> sendJson<T>(T value) async {
    final sendJson = _sendJson;
    if (sendJson == null) {
      return;
    }
    await sendJson(value);
  }

  /// Closes the WebSocket connection.
  Future<void> close([int? code, String? reason]) async {
    final close = _close;
    if (close == null) {
      return;
    }
    await close(code, reason);
  }
}
