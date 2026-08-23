import 'web_transport_stream.dart';

/// Incoming long-lived streams initiated by the WebTransport peer.
final class IncomingWebTransportReceiveStreams {
  const IncomingWebTransportReceiveStreams({
    Stream<WebTransportReceiveStream>? unidirectional,
    Stream<WebTransportBidirectionalStream>? bidirectional,
  }) : unidirectional = unidirectional ?? const Stream<WebTransportReceiveStream>.empty(),
       bidirectional = bidirectional ?? const Stream<WebTransportBidirectionalStream>.empty();

  /// Peer-initiated unidirectional streams, emitted as soon as they open.
  final Stream<WebTransportReceiveStream> unidirectional;

  /// Peer-initiated bidirectional streams, emitted as soon as they open.
  final Stream<WebTransportBidirectionalStream> bidirectional;
}
