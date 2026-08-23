/// One server-sent event emitted over an SSE response stream.
final class SseEvent {
  const SseEvent({this.data, this.event, this.id, this.retry, this.comment});

  /// Event payload sent as one or more `data:` lines.
  final String? data;

  /// Optional event type name.
  final String? event;

  /// Optional event ID used by EventSource reconnection.
  final String? id;

  /// Optional client reconnection hint.
  final Duration? retry;

  /// Optional comment frame.
  final String? comment;

  /// Encodes this event using the SSE wire format.
  String encode() {
    final buffer = StringBuffer();

    final comment = this.comment;
    if (comment case final comment?) {
      for (final line in _normalizedLines(comment)) {
        buffer.writeln(': $line');
      }
    }

    final id = this.id;
    if (id case final id?) {
      buffer.writeln('id: $id');
    }

    final event = this.event;
    if (event case final event?) {
      buffer.writeln('event: $event');
    }

    final retry = this.retry;
    if (retry case final retry?) {
      buffer.writeln('retry: ${retry.inMilliseconds}');
    }

    final data = this.data;
    if (data case final data?) {
      for (final line in _normalizedLines(data)) {
        buffer.writeln('data: $line');
      }
    }

    buffer.writeln();
    return buffer.toString();
  }
}

Iterable<String> _normalizedLines(String value) {
  final normalized = value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  return normalized.split('\n');
}
