import 'dart:typed_data';

import '../transport/binary_payload_lease.dart';

typedef WebTransportStreamWriter = Future<void> Function(List<int> value);
typedef WebTransportStreamLeaseWriter = Future<void> Function(BinaryPayloadLease lease);
typedef WebTransportStreamTerminator = Future<void> Function([int errorCode]);

/// The readable side of one long-lived WebTransport stream.
final class WebTransportReceiveStream {
  const WebTransportReceiveStream({
    required this.id,
    required this.protocolId,
    required this._leases,
    required this._stop,
  });

  /// Runtime-unique stream handle.
  final int id;

  /// QUIC stream identifier, unique within the WebTransport session.
  ///
  /// Browser WebTransport implementations do not expose this identifier.
  final int? protocolId;

  final Stream<BinaryPayloadLease> _leases;
  final WebTransportStreamTerminator _stop;

  /// Incremental native-owned chunks from this stream.
  ///
  /// Consumers must close every lease.
  Stream<BinaryPayloadLease> leases() => _leases;

  /// Incremental chunks copied into Dart-managed memory.
  Stream<Uint8List> chunks() => _leases.map((lease) => lease.takeBytes());

  /// Stops receiving and asks the peer to stop transmitting.
  Future<void> stop([int errorCode = 0]) => _stop(errorCode);
}

/// The writable side of one long-lived WebTransport stream.
final class WebTransportSendStream {
  const WebTransportSendStream({
    required this.id,
    required this.protocolId,
    required this._write,
    required this._writeLease,
    required this._finish,
    required this._reset,
  });

  /// Runtime-unique stream handle.
  final int id;

  /// QUIC stream identifier, unique within the WebTransport session.
  ///
  /// Browser WebTransport implementations do not expose this identifier.
  final int? protocolId;

  final WebTransportStreamWriter _write;
  final WebTransportStreamLeaseWriter _writeLease;
  final Future<void> Function() _finish;
  final WebTransportStreamTerminator _reset;

  /// Reliably writes all bytes, completing after QUIC flow control accepts them.
  Future<void> write(List<int> value) => _write(value);

  /// Reliably writes and consumes a single-owner payload lease.
  Future<void> writeLease(BinaryPayloadLease lease) => _writeLease(lease);

  /// Sends FIN and completes after all written bytes are acknowledged.
  Future<void> finish() => _finish();

  /// Immediately resets this sending side.
  Future<void> reset([int errorCode = 0]) => _reset(errorCode);
}

/// Both sides of one bidirectional WebTransport stream.
final class WebTransportBidirectionalStream {
  const WebTransportBidirectionalStream({required this.receive, required this.send});

  final WebTransportReceiveStream receive;
  final WebTransportSendStream send;

  int get id => send.id;
  int? get protocolId => send.protocolId;
}
