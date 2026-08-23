import 'dart:async';

import '../http/binary_stream_response.dart';
import '../http/raw_response.dart';
import '../http/sse_event.dart';
import '../http/sse_response.dart';

/// Mutable per-request response builder exposed as `ctx.res`.
///
/// Handlers can either:
/// - return a plain value and use this builder to override status, headers, or
///   content type
/// - return one of the terminal response helpers directly
/// - call a terminal helper without returning, in which case the runtime uses
///   the stored response draft
final class ResponseBuilder {
  int? _status;
  String? _contentType;
  Object? _body;
  var _hasBody = false;
  var _isEncodedBody = false;
  var _hasExplicitContentType = false;
  final List<HttpHeader> _headers = <HttpHeader>[];

  /// Status override applied to the success response.
  int? get statusOverride => _status;

  /// Content type override applied to the success response.
  String? get contentTypeOverride => _contentType;

  /// Body override applied to the success response.
  Object? get bodyOverride => _body;

  /// Whether a body was explicitly set on the builder.
  bool get hasBodyOverride => _hasBody;

  /// Whether the stored body is already encoded.
  bool get isEncodedBody => _isEncodedBody;

  /// Additional headers attached to the response.
  List<HttpHeader> get headers => List<HttpHeader>.unmodifiable(_headers);

  /// Sets the HTTP status code.
  ResponseBuilder status(int status) {
    _status = status;
    return this;
  }

  /// Fastify-style alias for [status].
  ResponseBuilder code(int status) => this.status(status);

  /// Adds one HTTP header.
  ResponseBuilder header(String name, String value) {
    _headers.add(HttpHeader(name, value));
    return this;
  }

  /// Sets the response content type.
  ResponseBuilder contentType(String contentType) {
    _contentType = contentType;
    _hasExplicitContentType = true;
    _isEncodedBody = false;
    return this;
  }

  /// Fastify-style alias for [contentType].
  ResponseBuilder type(String contentType) => this.contentType(contentType);

  /// Sends a JSON response.
  RawResponse json([Object? body]) {
    _contentType = 'application/json; charset=utf-8';
    _hasExplicitContentType = true;
    _isEncodedBody = false;
    _setBody(body);
    return _toRawResponse(
      status: _status ?? 200,
      contentType: _contentType!,
      body: body,
      isEncodedBody: _isEncodedBody,
    );
  }

  /// Sends a plain-text response.
  RawResponse text(String body) {
    _contentType = 'text/plain; charset=utf-8';
    _hasExplicitContentType = true;
    _isEncodedBody = false;
    _setBody(body);
    return _toRawResponse(
      status: _status ?? 200,
      contentType: _contentType!,
      body: body,
      isEncodedBody: _isEncodedBody,
    );
  }

  /// Sends an HTML response.
  RawResponse html(String body) {
    _contentType = 'text/html; charset=utf-8';
    _hasExplicitContentType = true;
    _isEncodedBody = false;
    _setBody(body);
    return _toRawResponse(
      status: _status ?? 200,
      contentType: _contentType!,
      body: body,
      isEncodedBody: false,
    );
  }

  /// Sends a body using the current content type or a best-effort default.
  ///
  /// When a JSON content type was set explicitly and [body] is a [String], the
  /// string is treated as already encoded JSON and forwarded as-is.
  RawResponse send([Object? body]) {
    _contentType ??= _inferContentType(body);
    _isEncodedBody = _hasExplicitContentType && body is String && _isJsonContentType(_contentType!);
    _setBody(body);
    return _toRawResponse(
      status: _status ?? 200,
      contentType: _contentType!,
      body: body,
      isEncodedBody: _isEncodedBody,
    );
  }

  /// Sends an already encoded body for [contentType].
  RawResponse encoded({required String contentType, String body = ''}) {
    _contentType = contentType;
    _hasExplicitContentType = true;
    _isEncodedBody = true;
    _setBody(body);
    return _toRawResponse(
      status: _status ?? 200,
      contentType: contentType,
      body: body,
      isEncodedBody: true,
    );
  }

  /// Sends already encoded binary bytes for [contentType].
  RawResponse binary({required String contentType, required List<int> body}) {
    _contentType = contentType;
    _hasExplicitContentType = true;
    _isEncodedBody = true;
    _setBody(body);
    return _toRawResponse(
      status: _status ?? 200,
      contentType: contentType,
      body: body,
      isEncodedBody: true,
    );
  }

  /// Streams an encoded binary body with transport-level backpressure.
  BinaryStreamResponse binaryStream({
    required String contentType,
    required Stream<List<int>> body,
    int? contentLength,
    List<HttpHeader> headers = const <HttpHeader>[],
    FutureOr<void> Function()? onDispose,
  }) {
    final response = BinaryStreamResponse(
      body: body,
      contentType: contentType,
      status: _status ?? 200,
      contentLength: contentLength,
      headers: [..._headers, ...headers],
      onDispose: onDispose,
    );
    _contentType = contentType;
    _hasExplicitContentType = true;
    _isEncodedBody = true;
    _setBody(response);
    return response;
  }

  /// Sends a server-sent events response.
  SseResponse sse(Stream<SseEvent> events, {List<HttpHeader> headers = const <HttpHeader>[]}) {
    final response = SseResponse(
      events: events,
      status: _status ?? 200,
      headers: [..._headers, ...headers],
    );
    _contentType = 'text/event-stream; charset=utf-8';
    _hasExplicitContentType = true;
    _isEncodedBody = false;
    _setBody(response);
    return response;
  }

  void _setBody(Object? body) {
    _body = body;
    _hasBody = true;
  }

  RawResponse _toRawResponse({
    required int status,
    required String contentType,
    required Object? body,
    required bool isEncodedBody,
  }) {
    return RawResponse(
      status: status,
      contentType: contentType,
      body: body,
      headers: headers,
      isEncodedBody: isEncodedBody,
    );
  }
}

String _inferContentType(Object? body) => switch (body) {
  String() => 'text/plain; charset=utf-8',
  _ => 'application/json; charset=utf-8',
};

bool _isJsonContentType(String contentType) {
  final mimeType = contentType.split(';').first.trim().toLowerCase();
  return mimeType == 'application/json' || mimeType.endsWith('+json');
}
