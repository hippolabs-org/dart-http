import 'dart:async';

import 'raw_response.dart';
import 'sse_event.dart';

/// Streaming HTTP response emitted as `text/event-stream`.
final class SseResponse {
  SseResponse({
    required this.events,
    this.status = 200,
    List<HttpHeader> headers = const <HttpHeader>[],
  }) : headers = List<HttpHeader>.unmodifiable(headers);

  /// Event stream forwarded to the client.
  final Stream<SseEvent> events;

  /// HTTP status code sent with the initial SSE response.
  final int status;

  /// Additional HTTP headers included in the initial response.
  final List<HttpHeader> headers;
}
