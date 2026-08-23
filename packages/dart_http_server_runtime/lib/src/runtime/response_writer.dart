import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_http_core/dart_http_core.dart';
import 'package:json_schema/json_schema.dart';

final class EncodedResponse {
  const EncodedResponse({
    required this.status,
    required this.contentType,
    required this.bodyBytes,
    this.headers = const <HttpHeader>[],
  });

  final int status;
  final String contentType;
  final List<HttpHeader> headers;
  final Uint8List bodyBytes;

  String get body => utf8.decode(bodyBytes, allowMalformed: true);
}

EncodedResponse encodeResponse({
  required ResponseSpec spec,
  required Object? body,
  ResponseBuilder? response,
}) {
  if (body case final RawResponse rawResponse) {
    return _encodeRawResponse(rawResponse);
  }

  final responseBuilder = response;
  final effectiveBody = responseBuilder != null && responseBuilder.hasBodyOverride
      ? responseBuilder.bodyOverride
      : body;
  final effectiveStatus = responseBuilder?.statusOverride ?? spec.status;
  final effectiveContentType = responseBuilder?.contentTypeOverride ?? spec.contentType;
  final headers = responseBuilder?.headers ?? const <HttpHeader>[];

  if (responseBuilder?.isEncodedBody ?? false) {
    return EncodedResponse(
      status: effectiveStatus,
      contentType: effectiveContentType,
      bodyBytes: _encodedBodyBytes(effectiveBody),
      headers: headers,
    );
  }

  if (_isJsonContentType(effectiveContentType)) {
    return EncodedResponse(
      status: effectiveStatus,
      contentType: effectiveContentType,
      bodyBytes: _textBytes(jsonEncode(_normalizeJson(effectiveBody))),
      headers: headers,
    );
  }

  return EncodedResponse(
    status: effectiveStatus,
    contentType: effectiveContentType,
    bodyBytes: _encodedBodyBytes(effectiveBody),
    headers: headers,
  );
}

EncodedResponse _encodeRawResponse(RawResponse response) {
  if (response.isEncodedBody) {
    return EncodedResponse(
      status: response.status,
      contentType: response.contentType,
      bodyBytes: _encodedBodyBytes(response.body),
      headers: response.headers,
    );
  }

  if (_isJsonContentType(response.contentType)) {
    return EncodedResponse(
      status: response.status,
      contentType: response.contentType,
      bodyBytes: _textBytes(jsonEncode(_normalizeJson(response.body))),
      headers: response.headers,
    );
  }

  return EncodedResponse(
    status: response.status,
    contentType: response.contentType,
    bodyBytes: _encodedBodyBytes(response.body),
    headers: response.headers,
  );
}

EncodedResponse encodeServerError() {
  return EncodedResponse(
    status: 500,
    contentType: 'text/plain; charset=utf-8',
    bodyBytes: _textBytes('Internal Server Error'),
  );
}

Uint8List _encodedBodyBytes(Object? body) {
  return switch (body) {
    null => Uint8List(0),
    Uint8List() => Uint8List.fromList(body),
    List<int>() => Uint8List.fromList(body),
    String() => _textBytes(body),
    _ => _textBytes(body.toString()),
  };
}

Uint8List _textBytes(String body) => Uint8List.fromList(utf8.encode(body));

Object? _normalizeJson(Object? value) {
  switch (value) {
    case null:
    case bool():
    case num():
    case String():
      return value;
    case List():
      return value.map(_normalizeJson).toList(growable: false);
    case Map():
      return {for (final entry in value.entries) entry.key.toString(): _normalizeJson(entry.value)};
    case JsonEncodable():
      return _normalizeJson(value.toJson());
    default:
      throw StateError('Response body of type ${value.runtimeType} is not JSON encodable.');
  }
}

bool _isJsonContentType(String contentType) {
  final mimeType = contentType.split(';').first.trim().toLowerCase();
  return mimeType == 'application/json' || mimeType.endsWith('+json');
}
