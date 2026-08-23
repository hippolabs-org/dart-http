import 'dart:typed_data';

/// One raw HTTP header attached to a [RawResponse].
final class HttpHeader {
  const HttpHeader(this.name, this.value);

  /// Header name.
  final String name;

  /// Header value.
  final String value;
}

/// Fully specified HTTP response returned directly from a route handler.
final class RawResponse {
  const RawResponse({
    required this.status,
    required this.contentType,
    this.body = '',
    this.headers = const <HttpHeader>[],
    this.isEncodedBody = false,
  });

  /// HTTP status code.
  final int status;

  /// Full response content type.
  final String contentType;

  /// Response body before encoding.
  final Object? body;

  /// Extra response headers.
  final List<HttpHeader> headers;

  /// Whether [body] is already encoded and should be forwarded as-is.
  final bool isEncodedBody;

  /// Creates a JSON response whose body will be encoded by the runtime.
  factory RawResponse.json({
    required int status,
    Object? body,
    List<HttpHeader> headers = const <HttpHeader>[],
  }) {
    return RawResponse(
      status: status,
      contentType: 'application/json; charset=utf-8',
      body: body,
      headers: headers,
    );
  }

  /// Creates a plain-text response.
  factory RawResponse.text({
    required int status,
    String body = '',
    List<HttpHeader> headers = const <HttpHeader>[],
  }) {
    return RawResponse(
      status: status,
      contentType: 'text/plain; charset=utf-8',
      body: body,
      headers: headers,
    );
  }

  /// Creates a response whose body is already encoded for [contentType].
  factory RawResponse.encoded({
    required int status,
    required String contentType,
    String body = '',
    List<HttpHeader> headers = const <HttpHeader>[],
  }) {
    return RawResponse(
      status: status,
      contentType: contentType,
      body: body,
      headers: headers,
      isEncodedBody: true,
    );
  }

  /// Creates a binary response whose bytes are already encoded for [contentType].
  factory RawResponse.binary({
    required int status,
    required String contentType,
    required Uint8List body,
    List<HttpHeader> headers = const <HttpHeader>[],
  }) {
    return RawResponse(
      status: status,
      contentType: contentType,
      body: body,
      headers: headers,
      isEncodedBody: true,
    );
  }

  /// Creates a `416 Range Not Satisfiable` response for a known resource size.
  factory RawResponse.rangeNotSatisfiable({required int totalLength}) {
    if (totalLength < 0) {
      throw ArgumentError.value(totalLength, 'totalLength', 'Must be >= 0.');
    }
    return RawResponse(
      status: 416,
      contentType: 'text/plain; charset=utf-8',
      headers: <HttpHeader>[
        const HttpHeader('Accept-Ranges', 'bytes'),
        HttpHeader('Content-Range', 'bytes */$totalLength'),
      ],
    );
  }
}
