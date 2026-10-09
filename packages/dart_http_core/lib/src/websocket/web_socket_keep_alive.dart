/// WebSocket keepalive using the protocol's ping and pong frames (RFC 6455
/// section 5.5.2).
///
/// The endpoint pings its peer every [interval]. When nothing at all arrives
/// within [timeout] of a ping (a pong or any other frame), the connection is
/// treated as dead and closed. Regular pings also keep idle connections open
/// through firewalls and proxies that drop silent flows.
final class WebSocketKeepAlive {
  const WebSocketKeepAlive({required this.interval, this.timeout = const Duration(seconds: 5)});

  /// Time between pings.
  final Duration interval;

  /// How long to wait for any frame after a ping before giving up.
  final Duration timeout;

  /// Throws when [interval] or [timeout] is not positive.
  void validate() {
    if (interval <= Duration.zero) {
      throw ArgumentError.value(interval, 'interval', 'WebSocket ping interval must be positive.');
    }
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'WebSocket pong timeout must be positive.');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is WebSocketKeepAlive && other.interval == interval && other.timeout == timeout;

  @override
  int get hashCode => Object.hash(interval, timeout);

  @override
  String toString() => 'WebSocketKeepAlive(interval: $interval, timeout: $timeout)';
}
