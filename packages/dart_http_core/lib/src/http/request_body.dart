import 'dart:async';

import 'package:json_schema/json_schema.dart';

import 'multipart_form_data.dart';

/// Decodes a parsed request body payload into an application type.
typedef RequestBodyDecoder = Object? Function(Object? value);

/// Decodes a parsed multipart form payload into an application type.
typedef MultipartBodyDecoder = FutureOr<Object?> Function(MultipartFormData form);

/// Controls how a server runtime delivers a request body to Dart.
enum RequestBodyDelivery {
  /// Decode or expose the complete request body after it has been collected.
  buffered,

  /// Expose a runtime-owned native byte stream without copying it into Dart.
  nativeStream,
}

/// Marker for a request body delivered as a runtime-native byte stream.
///
/// The concrete runtime package exposes the ownership-transfer operation.
abstract interface class DartHttpServerNativeBodyStream {
  /// Declared content length, when supplied by the peer.
  int? get contentLength;
}

/// Declares the request body expected by a [RouteOptions].
final class RequestBody {
  const RequestBody._({
    required this.contentType,
    this.schema,
    this.decoder,
    this.multipartDecoder,
    this.isBinary = false,
    this.delivery = RequestBodyDelivery.buffered,
  });

  /// Expected request content type.
  final String contentType;

  /// Optional schema used to validate or document the body.
  final JsonSchema? schema;

  /// Optional route-local decoder used after the transport parses the body.
  final RequestBodyDecoder? decoder;

  /// Optional route-local decoder used after multipart form-data parsing.
  final MultipartBodyDecoder? multipartDecoder;

  /// Whether the runtime must preserve this body as raw bytes.
  final bool isBinary;

  /// How a concrete server runtime should deliver this body.
  final RequestBodyDelivery delivery;

  /// Declares a JSON request body backed by [schema].
  const RequestBody.json({JsonSchema? schema, RequestBodyDecoder? decoder})
    : this._(contentType: 'application/json; charset=utf-8', schema: schema, decoder: decoder);

  /// Declares an untyped JSON request body.
  const RequestBody.jsonValue()
    : this._(contentType: 'application/json; charset=utf-8', schema: null, decoder: null);

  /// Declares a plain-text request body.
  const RequestBody.text()
    : this._(contentType: 'text/plain; charset=utf-8', schema: null, decoder: null);

  /// Declares a raw binary request body.
  ///
  /// Concrete runtimes expose the received value as bytes without attempting
  /// UTF-8 decoding. Use a more specific [contentType] when the protocol
  /// defines one, such as `application/partial-upload`.
  const RequestBody.binary({String contentType = 'application/octet-stream'})
    : this._(
        contentType: contentType,
        schema: const JsonSchema.string(format: 'binary'),
        decoder: null,
        isBinary: true,
      );

  /// Declares a binary body delivered through a native ownership stream.
  ///
  /// This avoids collecting the request in Dart-managed memory. It requires a
  /// server runtime and handler capable of consuming the native stream.
  const RequestBody.binaryStream({String contentType = 'application/octet-stream'})
    : this._(
        contentType: contentType,
        schema: const JsonSchema.string(format: 'binary'),
        decoder: null,
        isBinary: true,
        delivery: RequestBodyDelivery.nativeStream,
      );

  /// Declares a multipart form-data request body.
  const RequestBody.multipartFormData({JsonSchema? schema, MultipartBodyDecoder? decoder})
    : this._(
        contentType: 'multipart/form-data',
        schema: schema,
        decoder: null,
        multipartDecoder: decoder,
      );
}
