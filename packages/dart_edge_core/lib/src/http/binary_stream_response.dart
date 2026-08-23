import 'dart:async';

import 'http_byte_range.dart';
import 'raw_response.dart';

/// Backpressured streaming response for an encoded binary HTTP body.
final class BinaryStreamResponse {
  const BinaryStreamResponse({
    required this.body,
    required this.contentType,
    this.status = 200,
    this.contentLength,
    this.headers = const <HttpHeader>[],
    this.onDispose,
  }) : assert(contentLength == null || contentLength >= 0);

  /// Creates a `206 Partial Content` response for [range].
  factory BinaryStreamResponse.partial({
    required Stream<List<int>> body,
    required String contentType,
    required HttpByteRangeSelection range,
    List<HttpHeader> headers = const <HttpHeader>[],
    FutureOr<void> Function()? onDispose,
  }) {
    return BinaryStreamResponse(
      body: body,
      contentType: contentType,
      status: 206,
      contentLength: range.contentLength,
      headers: [...headers, ...range.responseHeaders],
      onDispose: onDispose,
    );
  }

  /// Chunks emitted in wire order.
  final Stream<List<int>> body;

  /// Full response content type.
  final String contentType;

  /// HTTP status code.
  final int status;

  /// Total encoded body length, when known before streaming starts.
  final int? contentLength;

  /// Extra response headers.
  final List<HttpHeader> headers;

  /// Releases resources acquired before the body was listened to.
  ///
  /// The runtime invokes this after normal completion, cancellation, failure,
  /// or when the native response cannot be started.
  final FutureOr<void> Function()? onDispose;

  /// Releases response-owned resources, when configured.
  Future<void> dispose() async {
    await onDispose?.call();
  }
}
