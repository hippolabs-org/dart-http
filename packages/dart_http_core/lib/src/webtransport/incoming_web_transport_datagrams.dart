import 'dart:typed_data';

import '../transport/binary_payload_lease.dart';

/// Accessor for incoming WebTransport datagrams exposed to a route handler.
final class IncomingWebTransportDatagrams {
  const IncomingWebTransportDatagrams([Stream<Uint8List>? datagrams])
    : _datagrams = datagrams ?? const Stream<Uint8List>.empty(),
      _leases = null;

  const IncomingWebTransportDatagrams.leased(Stream<BinaryPayloadLease> leases)
    : _datagrams = null,
      _leases = leases;

  final Stream<Uint8List>? _datagrams;
  final Stream<BinaryPayloadLease>? _leases;

  /// Incoming unreliable datagrams.
  Stream<Uint8List> datagrams() {
    final datagrams = _datagrams;
    if (datagrams != null) return datagrams;
    return _leases!.map((lease) => lease.takeBytes());
  }

  /// Incoming datagrams as single-owner payload leases.
  ///
  /// Consumers must close each lease. Native runtimes can expose these without
  /// allocating Dart-managed payload bytes.
  Stream<BinaryPayloadLease> leases() {
    final leases = _leases;
    if (leases != null) return leases;
    return _datagrams!.map(BinaryPayloadLease.fromBytes);
  }
}
