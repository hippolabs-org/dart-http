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
      bodyBytes: _jsonBytes(effectiveBody),
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
      bodyBytes: _jsonBytes(response.body),
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

EncodedResponse encodeBadRequest() {
  return EncodedResponse(
    status: 400,
    contentType: 'application/json; charset=utf-8',
    bodyBytes: _textBytes('{"code":"INVALID_REQUEST"}'),
  );
}

/// Response bytes for [body] without copying bytes the handler already owns.
///
/// A [Uint8List] is used as-is: the runtime copies it into native memory
/// exactly once, synchronously, before the handler can observe the response.
Uint8List _encodedBodyBytes(Object? body) {
  return switch (body) {
    null => Uint8List(0),
    Uint8List() => body,
    List<int>() => Uint8List.fromList(body),
    String() => _textBytes(body),
    _ => _textBytes(body.toString()),
  };
}

Uint8List _textBytes(String body) => utf8.encode(body);

/// Encodes JSON straight to UTF-8 bytes, without an intermediate String or a
/// normalized copy of the value graph.
Uint8List _jsonBytes(Object? body) => _jsonUtf8Encoder.convert(body) as Uint8List;

final _jsonUtf8Encoder = JsonUtf8Encoder(null, _toEncodableJson, 16 * 1024);

/// Called by the JSON encoder only for values it cannot write directly:
/// [JsonEncodable] objects and maps whose keys are not all strings.
Object? _toEncodableJson(Object? value) {
  final json = value is JsonEncodable ? value.toJson() : value;
  return switch (json) {
    null || bool() || num() || String() || List() => json,
    Map() when json.keys.every((key) => key is String) => json,
    Map() => {for (final entry in json.entries) entry.key.toString(): entry.value},
    JsonEncodable() => _toEncodableJson(json),
    _ => throw StateError('Response body of type ${value.runtimeType} is not JSON encodable.'),
  };
}

bool _isJsonContentType(String contentType) {
  final mimeType = contentType.split(';').first.trim().toLowerCase();
  return mimeType == 'application/json' || mimeType.endsWith('+json');
}
