import 'dart:typed_data';

import '../transport/binary_payload_lease.dart';

/// Accessor for incoming reliable WebTransport stream payloads.
///
/// Each item is the full payload from one completed unidirectional
/// WebTransport stream.
final class IncomingWebTransportStreams {
  const IncomingWebTransportStreams([Stream<Uint8List>? streams])
    : _streams = streams ?? const Stream<Uint8List>.empty(),
      _leases = null;

  const IncomingWebTransportStreams.leased(Stream<BinaryPayloadLease> leases)
    : _streams = null,
      _leases = leases;

  final Stream<Uint8List>? _streams;
  final Stream<BinaryPayloadLease>? _leases;

  /// Incoming reliable stream payloads.
  Stream<Uint8List> streams() {
    final streams = _streams;
    if (streams != null) return streams;
    return _leases!.map((lease) => lease.takeBytes());
  }

  /// Reliable stream payloads as single-owner leases.
  ///
  /// Consumers must close each lease. Native runtimes can expose these without
  /// allocating Dart-managed payload bytes.
  Stream<BinaryPayloadLease> leases() {
    final leases = _leases;
    if (leases != null) return leases;
    return _streams!.map(BinaryPayloadLease.fromBytes);
  }
}
