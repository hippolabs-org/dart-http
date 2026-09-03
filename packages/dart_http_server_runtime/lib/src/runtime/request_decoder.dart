import 'dart:convert';

import 'package:dart_http_core/dart_http_core.dart';

import 'dart_http_codec.dart';
import 'json_schema_route_id.dart';
import 'native_request.dart';
import 'transport_request.dart';

Future<RequestInput> decodeRequestInput(
  TransportRequest request, {
  required DartHttpCodecRegistry codecs,
  NativeRequest? nativeRequest,
  required String? paramsSchemaId,
  required String? querySchemaId,
  required String? headersSchemaId,
  RequestValueDecoder? paramsDecoder,
  RequestValueDecoder? queryDecoder,
  required RequestBody? body,
}) async {
  final paramsValue = _decodeStringMap(
    request.pathParams,
    schemaId: paramsSchemaId,
    decoder: paramsDecoder,
    codecs: codecs,
  );
  final queryValue = _decodeStringMap(
    request.query,
    schemaId: querySchemaId,
    decoder: queryDecoder,
    codecs: codecs,
  );
  final headerValue = _decodeStringMap(request.headers, schemaId: headersSchemaId, codecs: codecs);
  final bodyValue = await _decodeBody(request, body, codecs: codecs, nativeRequest: nativeRequest);

  return RequestInput(
    params: paramsValue,
    query: queryValue,
    headers: headerValue,
    body: bodyValue,
    paramsMap: request.pathParams,
    queryMap: request.query,
    headersMap: request.headers,
    multipartLoader: nativeRequest?.multipart,
    nativeBody: nativeRequest?.bodyStream ?? nativeRequest?.body,
  );
}

Object? _decodeStringMap(
  Map<String, String> values, {
  required String? schemaId,
  RequestValueDecoder? decoder,
  required DartHttpCodecRegistry codecs,
}) {
  if (values.isEmpty) {
    return null;
  }

  final decodedValues = Map<String, String>.unmodifiable(values);
  if (decoder case final decoder?) {
    return decoder(decodedValues);
  }

  return codecs.decodeValueOrRaw(schemaId, decodedValues);
}

Future<Object?> _decodeBody(
  TransportRequest request,
  RequestBody? body, {
  required DartHttpCodecRegistry codecs,
  required NativeRequest? nativeRequest,
}) async {
  if (body == null) {
    return null;
  }

  if (body.delivery == RequestBodyDelivery.nativeStream) {
    if (nativeRequest?.bodyStream == null) {
      throw StateError('The native runtime did not provide the declared request body stream.');
    }
    return null;
  }

  if (request.bodyKind == TransportRequestBodyKind.multipart) {
    final decoder = body.multipartDecoder;
    if (decoder == null) {
      return null;
    }
    final form = await nativeRequest?.multipart();
    if (form == null) {
      throw StateError('No multipart form-data parser is available.');
    }
    return decoder(form.toMultipartFormData());
  }

  final payload = request.bodyBytes;
  if (payload == null || payload.isEmpty) {
    return null;
  }

  final decoded = switch (request.bodyKind) {
    TransportRequestBodyKind.json => jsonDecode(utf8.decode(payload)),
    _ when body.contentType.startsWith('application/json') => jsonDecode(utf8.decode(payload)),
    _ when body.isBinary => payload,
    _ => utf8.decode(payload),
  };

  if (body.decoder case final decoder?) {
    return decoder(decoded);
  }

  return codecs.decodeValueOrRaw(jsonSchemaRouteId(body.schema), decoded);
}
