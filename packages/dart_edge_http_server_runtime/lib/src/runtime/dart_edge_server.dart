/// Handle returned from [DartEdge.listen].
///
/// It owns the active server session and can be used to stop the server.
final class DartEdgeServer {
  DartEdgeServer({required this.host, required this.port, required this.onClose});

  /// Bound host address.
  final String host;

  /// Bound TCP port.
  final int port;
  final Future<void> Function() onClose;

  /// Stops the running server.
  Future<void> close() => onClose();
}
