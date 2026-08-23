import 'dart:typed_data';

import '../context/request_context.dart';
import '../context/request_input.dart';
import '../context/request_telemetry.dart';
import '../transport/binary_payload_lease.dart';
import 'incoming_web_transport_datagrams.dart';
import 'incoming_web_transport_receive_streams.dart';
import 'incoming_web_transport_streams.dart';
import 'web_transport_stream.dart';

typedef WebTransportDatagramSender = Future<void> Function(List<int> value);
typedef WebTransportStreamSender = Future<void> Function(List<int> value);
typedef WebTransportLeaseSender = Future<void> Function(BinaryPayloadLease lease);
typedef WebTransportCloser = Future<void> Function([int? code, String? reason]);
typedef WebTransportUnidirectionalStreamOpener = Future<WebTransportSendStream> Function();
typedef WebTransportBidirectionalStreamOpener = Future<WebTransportBidirectionalStream> Function();

/// Context passed to a WebTransport route when a client connects.
final class WebTransportContext<TServices> {
  WebTransportContext({
    required this.services,
    this.req = RequestInput.empty,
    this.datagrams = const IncomingWebTransportDatagrams(),
    this.streams = const IncomingWebTransportStreams(),
    this.incomingStreams = const IncomingWebTransportReceiveStreams(),
    this.telemetry = const RequestTelemetry(),
    this._sendDatagram,
    this._sendDatagramLease,
    this._sendStream,
    this._sendStreamLease,
    this._openUnidirectionalStream,
    this._openBidirectionalStream,
    this._close,
  }) : _requestContext = RequestContext<TServices>(
         services: services,
         req: req,
         telemetry: telemetry,
       );

  WebTransportContext.fromRequest({
    required RequestContext<TServices> request,
    this.datagrams = const IncomingWebTransportDatagrams(),
    this.streams = const IncomingWebTransportStreams(),
    this.incomingStreams = const IncomingWebTransportReceiveStreams(),
    this._sendDatagram,
    this._sendDatagramLease,
    this._sendStream,
    this._sendStreamLease,
    this._openUnidirectionalStream,
    this._openBidirectionalStream,
    this._close,
  }) : services = request.services,
       req = request.req,
       telemetry = request.telemetry,
       _requestContext = request;

  /// Fresh services instance for the WebTransport session.
  final TServices services;

  /// Decoded request params, query, and headers for the CONNECT request.
  final RequestInput req;

  /// Incoming unreliable datagrams.
  final IncomingWebTransportDatagrams datagrams;

  /// Incoming reliable stream payloads.
  final IncomingWebTransportStreams streams;

  /// Peer-initiated long-lived unidirectional and bidirectional streams.
  final IncomingWebTransportReceiveStreams incomingStreams;

  /// Telemetry hook associated with the session lifecycle.
  final RequestTelemetry telemetry;

  final RequestContext<TServices> _requestContext;
  final WebTransportDatagramSender? _sendDatagram;
  final WebTransportLeaseSender? _sendDatagramLease;
  final WebTransportStreamSender? _sendStream;
  final WebTransportLeaseSender? _sendStreamLease;
  final WebTransportUnidirectionalStreamOpener? _openUnidirectionalStream;
  final WebTransportBidirectionalStreamOpener? _openBidirectionalStream;
  final WebTransportCloser? _close;

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

  /// Sends one unreliable datagram to the client.
  Future<void> sendDatagram(List<int> value) async {
    final sendDatagram = _sendDatagram;
    if (sendDatagram == null) {
      return;
    }
    await sendDatagram(Uint8List.fromList(value));
  }

  /// Sends and consumes one single-owner unreliable datagram payload.
  Future<void> sendDatagramLease(BinaryPayloadLease lease) async {
    try {
      final sendDatagramLease = _sendDatagramLease;
      if (sendDatagramLease != null) {
        await sendDatagramLease(lease);
        return;
      }
      await sendDatagram(lease.bytesView);
    } finally {
      lease.close();
    }
  }

  /// Sends one reliable payload on a new unidirectional WebTransport stream.
  Future<void> sendStream(List<int> value) async {
    final sendStream = _sendStream;
    if (sendStream == null) {
      return;
    }
    await sendStream(Uint8List.fromList(value));
  }

  /// Sends and consumes one single-owner reliable stream payload.
  Future<void> sendStreamLease(BinaryPayloadLease lease) async {
    try {
      final sendStreamLease = _sendStreamLease;
      if (sendStreamLease != null) {
        await sendStreamLease(lease);
        return;
      }
      await sendStream(lease.bytesView);
    } finally {
      lease.close();
    }
  }

  /// Opens one persistent, reliable unidirectional sending stream.
  Future<WebTransportSendStream> openUnidirectionalStream() {
    final open = _openUnidirectionalStream;
    if (open == null) {
      throw UnsupportedError('Persistent WebTransport streams are unavailable.');
    }
    return open();
  }

  /// Alias for [openUnidirectionalStream].
  Future<WebTransportSendStream> openSendStream() => openUnidirectionalStream();

  /// Opens one persistent, reliable bidirectional stream.
  Future<WebTransportBidirectionalStream> openBidirectionalStream() {
    final open = _openBidirectionalStream;
    if (open == null) {
      throw UnsupportedError('Bidirectional WebTransport streams are unavailable.');
    }
    return open();
  }

  /// Closes the WebTransport session.
  Future<void> close([int? code, String? reason]) async {
    final close = _close;
    if (close == null) {
      return;
    }
    await close(code, reason);
  }
}
