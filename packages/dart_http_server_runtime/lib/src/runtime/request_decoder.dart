import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dart_http_core/dart_http_core.dart';

import 'dart_http_codec.dart';
import 'json_schema_route_id.dart';
import 'native_request.dart';
import 'transport_request.dart';

final class RequestDecodeCapacityException implements Exception {
  const RequestDecodeCapacityException();
}

// Native inputs remain borrowed until the worker exits. There is deliberately
// no timeout that could release a request while an isolate still reads it.
final _bodyDecodeAdmission = _BodyDecodeAdmission();

final class _BodyDecodeAdmission {
  final _waiting = Queue<Completer<void>>();
  var _active = 0;
  var _bytes = 0;

  Future<Object?> run(int bytes, Future<Object?> Function() operation) async {
    if (bytes > 256 * 1024 * 1024 - _bytes || (_active >= 2 && _waiting.length >= 16)) {
      throw const RequestDecodeCapacityException();
    }
    _bytes += bytes;
    if (_active >= 2) {
      final ready = Completer<void>();
      _waiting.add(ready);
      await ready.future;
    } else {
      _active++;
    }
    try {
      return await operation();
    } finally {
      _bytes -= bytes;
      if (_waiting.isEmpty) {
        _active--;
      } else {
        _waiting.removeFirst().complete();
      }
    }
  }
}

Object? _parseBodyBytes(Uint8List bytes, int mode) {
  final text = utf8.decode(bytes);
  return switch (mode) {
    1 => jsonDecode(text),
    2 => Uri.splitQueryString(text),
    _ => text,
  };
}

Future<Object?> _parseNativeBody(int address, int length, int mode) => _bodyDecodeAdmission.run(
  length,
  () => Isolate.run(
    () => _parseBodyBytes(Pointer<Uint8>.fromAddress(address).asTypedList(length), mode),
  ),
);

Future<Object?> _parseManagedBody(TransferableTypedData bytes, int length, int mode) =>
    _bodyDecodeAdmission.run(
      length,
      () => Isolate.run(() => _parseBodyBytes(bytes.materialize().asUint8List(), mode)),
    );

/// A malformed HTTP request value rejected before route handling.
final class RequestDecodingException implements Exception {
  const RequestDecodingException();
}

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
  try {
    return await _decodeRequestInput(
      request,
      codecs: codecs,
      nativeRequest: nativeRequest,
      paramsSchemaId: paramsSchemaId,
      querySchemaId: querySchemaId,
      headersSchemaId: headersSchemaId,
      paramsDecoder: paramsDecoder,
      queryDecoder: queryDecoder,
      body: body,
    );
  } on FormatException {
    throw const RequestDecodingException();
  } on TypeError {
    throw const RequestDecodingException();
  }
}

Future<RequestInput> _decodeRequestInput(
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
  if (values.isEmpty && decoder == null) {
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

  final mode = switch (request.bodyKind) {
    TransportRequestBodyKind.json => 1,
    _ when body.contentType.startsWith('application/json') => 1,
    _ when body.contentType.startsWith('application/x-www-form-urlencoded') => 2,
    _ when body.isBinary => -1,
    _ => 0,
  };
  final nativeBody = request.nativeBody;
  final Object? decoded;
  if (mode >= 0 && nativeBody != null && nativeBody.length >= 64 * 1024) {
    final bytes = nativeBody.nativeBytes;
    decoded = await _parseNativeBody(bytes.ptr.address, bytes.len, mode);
  } else {
    final payload = request.bodyBytes;
    if (payload == null || payload.isEmpty) return null;
    decoded = mode == -1
        ? payload
        : payload.length >= 64 * 1024
        ? await _parseManagedBody(TransferableTypedData.fromList([payload]), payload.length, mode)
        : _parseBodyBytes(payload, mode);
  }

  if (body.decoder case final decoder?) {
    return decoder(decoded);
  }

  return codecs.decodeValueOrRaw(jsonSchemaRouteId(body.schema), decoded);
}
