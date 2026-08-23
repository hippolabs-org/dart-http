import 'dart:async';

import 'package:json_schema/json_schema.dart';

import 'multipart_form_data.dart';

/// Decodes a parsed request body payload into an application type.
typedef RequestBodyDecoder = Object? Function(Object? value);

/// Decodes a parsed multipart form payload into an application type.
typedef MultipartBodyDecoder = FutureOr<Object?> Function(MultipartFormData form);

/// Declares the request body expected by a [RouteOptions].
final class RequestBody {
  const RequestBody._({
    required this.contentType,
    this.schema,
    this.decoder,
    this.multipartDecoder,
  });

  /// Expected request content type.
  final String contentType;

  /// Optional schema used to validate or document the body.
  final JsonSchema? schema;

  /// Optional route-local decoder used after the transport parses the body.
  final RequestBodyDecoder? decoder;

  /// Optional route-local decoder used after multipart form-data parsing.
  final MultipartBodyDecoder? multipartDecoder;

  /// Declares a JSON request body backed by [schema].
  const RequestBody.json({JsonSchema? schema, RequestBodyDecoder? decoder})
    : this._(contentType: 'application/json; charset=utf-8', schema: schema, decoder: decoder);

  /// Declares an untyped JSON request body.
  const RequestBody.jsonValue()
    : this._(contentType: 'application/json; charset=utf-8', schema: null, decoder: null);

  /// Declares a plain-text request body.
  const RequestBody.text()
    : this._(contentType: 'text/plain; charset=utf-8', schema: null, decoder: null);

  /// Declares a multipart form-data request body.
  const RequestBody.multipartFormData({JsonSchema? schema, MultipartBodyDecoder? decoder})
    : this._(
        contentType: 'multipart/form-data',
        schema: schema,
        decoder: null,
        multipartDecoder: decoder,
      );
}
