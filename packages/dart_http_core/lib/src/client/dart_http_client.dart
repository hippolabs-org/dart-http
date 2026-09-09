import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../http.dart';
import 'dart_http_client_transport.dart';

/// Base class that typed HTTP clients extend.
abstract base class DartHttpClientBase {
  const DartHttpClientBase({
    required this.baseUri,
    required this.transport,
    this.webSocketTransport,
    this.webTransportTransport,
    this.defaultHeaders = const <String, String>{},
  });

  final Uri baseUri;
  final HttpClientTransport transport;
  final DartHttpClientWebSocketTransport? webSocketTransport;
  final DartHttpClientWebTransportTransport? webTransportTransport;
  final Map<String, String> defaultHeaders;

  Future<DartHttpClientResponseObject<TResponse>> invoke<
    TResponse,
    TParams,
    TQuery,
    THeaders,
    TBody
  >(DartHttpClientInvocation<TResponse, TParams, TQuery, THeaders, TBody> invocation) async {
    final abortTrigger = _combinedAbortTrigger(
      abortTrigger: invocation.abortTrigger,
      timeout: invocation.timeout,
    );
    final encodedBody = await _encodeRequestBody(
      body: invocation.body,
      onMultipartUploadProgress: invocation.onMultipartUploadProgress,
    );
    final request = DartHttpClientRequest(
      method: invocation.method,
      uri: _buildUri(invocation.pathTemplate, params: invocation.params, query: invocation.query),
      headers: _buildHeaders(
        headers: invocation.headers,
        body: invocation.body,
        encodedBody: encodedBody,
      ),
      body: encodedBody?.body,
      bodyStream: encodedBody?.bodyStream,
      bodyStreamLength: encodedBody?.bodyStreamLength,
      abortTrigger: abortTrigger,
    );

    final response = await transport.send(request);
    if (response.status == invocation.success.status) {
      return DartHttpClientResponseObject<TResponse>(
        status: response.status,
        contentType: response.contentType,
        headers: response.headers,
        rawBody: response.body,
        rawBodyBytes: response.bodyBytes,
        data: _decodeResponse<TResponse>(response, success: invocation.success),
      );
    }

    final documentedError = invocation.errors
        .where((error) => error.status == response.status)
        .firstOrNull;
    return DartHttpClientResponseObject<TResponse>(
      status: response.status,
      contentType: response.contentType,
      headers: response.headers,
      rawBody: response.body,
      rawBodyBytes: response.bodyBytes,
      error: DartHttpClientError(
        status: response.status,
        code: documentedError?.code,
        kind: documentedError == null
            ? DartHttpClientErrorKind.unknownStatus
            : DartHttpClientErrorKind.documented,
        contentType: response.contentType,
        headers: response.headers,
        rawBody: response.body,
        rawBodyBytes: response.bodyBytes,
        body: _decodeErrorBody(response),
      ),
    );
  }

  Future<DartHttpClientStreamedResponseObject> invokeStream<TParams, TQuery, THeaders, TBody>(
    DartHttpClientInvocation<Object?, TParams, TQuery, THeaders, TBody> invocation,
  ) async {
    final request = await _buildClientRequest(
      invocation,
      responseMode: invocation.success.responseMode,
    );
    final response = await transport.sendStream(request);
    if (response.status == invocation.success.status) {
      return DartHttpClientStreamedResponseObject(
        status: response.status,
        contentType: response.contentType,
        headers: response.headers,
        bodyStream: response.bodyStream,
      );
    }

    final bodyBytes = await _collectStreamBytes(response.bodyStream);
    final bufferedResponse = DartHttpClientResponse(
      status: response.status,
      contentType: response.contentType,
      headers: response.headers,
      bodyBytes: bodyBytes,
    );
    final documentedError = invocation.errors
        .where((error) => error.status == response.status)
        .firstOrNull;
    return DartHttpClientStreamedResponseObject(
      status: response.status,
      contentType: response.contentType,
      headers: response.headers,
      bodyStream: const Stream<List<int>>.empty(),
      error: DartHttpClientError(
        status: response.status,
        code: documentedError?.code,
        kind: documentedError == null
            ? DartHttpClientErrorKind.unknownStatus
            : DartHttpClientErrorKind.documented,
        contentType: response.contentType,
        headers: response.headers,
        rawBody: bufferedResponse.body,
        rawBodyBytes: bufferedResponse.bodyBytes,
        body: _decodeErrorBody(bufferedResponse),
      ),
    );
  }

  Future<DartHttpClientWebSocket> connectWebSocket<TParams, TQuery, THeaders>(
    DartHttpClientWebSocketInvocation<TParams, TQuery, THeaders> invocation,
  ) {
    final transport = webSocketTransport;
    if (transport == null) {
      throw StateError('No DartHttpClientWebSocketTransport configured for this client.');
    }

    final httpUri = _buildUri(
      invocation.pathTemplate,
      params: invocation.params,
      query: invocation.query,
    );
    return transport.connect(
      DartHttpClientWebSocketRequest(
        uri: _webSocketUri(httpUri),
        headers: _buildHeaders<THeaders, Never>(
          headers: invocation.headers,
          body: null,
          encodedBody: null,
        ),
        protocols: invocation.protocols,
      ),
    );
  }

  Future<DartHttpClientWebTransportSession> connectWebTransport<TParams, TQuery, THeaders>(
    DartHttpClientWebTransportInvocation<TParams, TQuery, THeaders> invocation,
  ) {
    final transport = webTransportTransport;
    if (transport == null) {
      throw StateError('No DartHttpClientWebTransportTransport configured for this client.');
    }

    final httpUri = _buildUri(
      invocation.pathTemplate,
      params: invocation.params,
      query: invocation.query,
    );
    return transport.connect(
      DartHttpClientWebTransportRequest(
        uri: _httpsUri(httpUri),
        headers: _buildHeaders<THeaders, Never>(
          headers: invocation.headers,
          body: null,
          encodedBody: null,
        ),
      ),
    );
  }

  Future<DartHttpClientRequest> _buildClientRequest<TResponse, TParams, TQuery, THeaders, TBody>(
    DartHttpClientInvocation<TResponse, TParams, TQuery, THeaders, TBody> invocation, {
    DartHttpClientResponseMode responseMode = DartHttpClientResponseMode.buffered,
  }) async {
    final abortTrigger = _combinedAbortTrigger(
      abortTrigger: invocation.abortTrigger,
      timeout: invocation.timeout,
    );
    final encodedBody = await _encodeRequestBody(
      body: invocation.body,
      onMultipartUploadProgress: invocation.onMultipartUploadProgress,
    );
    return DartHttpClientRequest(
      method: invocation.method,
      uri: _buildUri(invocation.pathTemplate, params: invocation.params, query: invocation.query),
      headers: _buildHeaders(
        headers: invocation.headers,
        body: invocation.body,
        encodedBody: encodedBody,
      ),
      body: encodedBody?.body,
      bodyStream: encodedBody?.bodyStream,
      bodyStreamLength: encodedBody?.bodyStreamLength,
      abortTrigger: abortTrigger,
      responseMode: responseMode,
    );
  }

  Uri _buildUri<TParams, TQuery>(
    String pathTemplate, {
    required DartHttpClientRequestValue<TParams>? params,
    required DartHttpClientRequestValue<TQuery>? query,
  }) {
    final resolvedPath = _joinPaths(
      baseUri.path,
      _resolvePathTemplate(pathTemplate, params: params),
    );
    final queryParametersAll = _normalizeQueryValues(_encodeObject(query));

    return baseUri.replace(
      path: resolvedPath,
      query: queryParametersAll.isEmpty ? null : _encodeQueryString(queryParametersAll),
    );
  }

  Map<String, String> _buildHeaders<THeaders, TBody>({
    required DartHttpClientRequestValue<THeaders>? headers,
    required DartHttpClientRequestBody<TBody>? body,
    required _EncodedClientRequestBody? encodedBody,
  }) {
    final builtHeaders = <String, String>{
      ...defaultHeaders,
      ..._normalizeHeaderValues(_encodeObject(headers)),
    };

    if (body case final body? when body.value != null) {
      builtHeaders.putIfAbsent('content-type', () => encodedBody?.contentType ?? body.contentType);
    }

    return builtHeaders;
  }

  Future<_EncodedClientRequestBody?> _encodeRequestBody<TBody>({
    required DartHttpClientRequestBody<TBody>? body,
    required void Function(DartHttpMultipartUploadProgress progress)? onMultipartUploadProgress,
  }) async {
    if (body == null || body.value == null) {
      return null;
    }

    final encodedBody = body.encode();
    final contentType = body.contentType.toLowerCase();

    if (_isJsonContentType(contentType)) {
      return _EncodedClientRequestBody(
        contentType: body.contentType,
        body: jsonEncode(encodedBody),
      );
    }

    if (_isTextContentType(contentType)) {
      return _EncodedClientRequestBody(
        contentType: body.contentType,
        body: encodedBody?.toString() ?? '',
      );
    }

    if (_isUrlEncodedContentType(contentType)) {
      if (encodedBody is! Map) {
        throw StateError('Expected a Map for an application/x-www-form-urlencoded request body.');
      }
      return _EncodedClientRequestBody(
        contentType: body.contentType,
        body: encodedBody.entries
            .map(
              (entry) =>
                  '${Uri.encodeQueryComponent(entry.key.toString())}='
                  '${Uri.encodeQueryComponent(entry.value.toString())}',
            )
            .join('&'),
      );
    }

    if (_isMultipartFormDataContentType(contentType)) {
      final form = encodedBody is MultipartFormData
          ? encodedBody
          : throw StateError('Expected MultipartFormData for multipart request body.');
      final encoded = _encodeMultipartFormData(form);
      return _EncodedClientRequestBody(
        contentType: 'multipart/form-data; boundary=${encoded.boundary}',
        bodyStream: _trackMultipartUploadProgress(
          encoded.bodyStream,
          totalBytes: encoded.bodyStreamLength,
          onProgress: onMultipartUploadProgress,
        ),
        bodyStreamLength: encoded.bodyStreamLength,
      );
    }

    return _EncodedClientRequestBody(contentType: body.contentType, body: encodedBody?.toString());
  }

  T _decodeResponse<T>(
    DartHttpClientResponse response, {
    required DartHttpClientResponseSpec<T> success,
  }) {
    if (_isJsonContentType(success.contentType)) {
      final decoded = response.body.isEmpty ? null : jsonDecode(response.body);
      if (success.decoder case final decoder?) {
        return decoder(decoded);
      }
      return decoded as T;
    }

    if (_isTextContentType(success.contentType)) {
      return response.body as T;
    }

    if (_isBinaryContentType(success.contentType)) {
      return response.bodyBytes as T;
    }

    if (success.decoder case final decoder?) {
      return decoder(response.body);
    }

    return response.body as T;
  }

  Object? _decodeErrorBody(DartHttpClientResponse response) {
    if (response.body.isEmpty) {
      return null;
    }
    if (_isJsonContentType(response.contentType)) {
      return jsonDecode(response.body);
    }
    if (_isTextContentType(response.contentType)) {
      return response.body;
    }
    if (_isBinaryContentType(response.contentType)) {
      return response.bodyBytes;
    }
    return response.body;
  }

  String _resolvePathTemplate<TParams>(
    String template, {
    required DartHttpClientRequestValue<TParams>? params,
  }) {
    final encodedParams = _normalizeScalarValues(_encodeObject(params));

    return template.replaceAllMapped(_pathParameterPattern, (match) {
      final name = match.group(1)!;
      final value = encodedParams[name];
      if (value == null) {
        throw StateError('Missing path parameter "$name" for template "$template".');
      }
      return Uri.encodeComponent(value);
    });
  }

  Map<String, Object?> _encodeObject<T>(DartHttpClientRequestValue<T>? value) {
    if (value == null || value.value == null) {
      return const <String, Object?>{};
    }

    final encoded = value.encode();
    if (encoded == null) {
      return const <String, Object?>{};
    }
    if (encoded is Map<String, Object?>) {
      return encoded;
    }
    if (encoded is Map) {
      return {for (final entry in encoded.entries) '${entry.key}': entry.value};
    }

    throw StateError(
      'Expected an encoded object map for schema "${value.schemaId}", '
      'but got ${encoded.runtimeType}.',
    );
  }

  Map<String, String> _normalizeHeaderValues(Map<String, Object?> values) {
    return {
      for (final entry in values.entries)
        if (entry.value case final value?) entry.key: _stringifyScalar(value),
    };
  }

  Map<String, String> _normalizeScalarValues(Map<String, Object?> values) {
    return {
      for (final entry in values.entries)
        if (entry.value case final value?) entry.key: _stringifyScalar(value),
    };
  }

  Map<String, List<String>> _normalizeQueryValues(Map<String, Object?> values) {
    final query = <String, List<String>>{};
    for (final entry in values.entries) {
      final value = entry.value;
      if (value == null) {
        continue;
      }

      query[entry.key] = switch (value) {
        String _ => [value],
        Iterable<Object?> _ => [
          for (final item in value)
            if (item != null) _stringifyScalar(item),
        ],
        _ => [_stringifyScalar(value)],
      };
    }
    return query;
  }

  String _stringifyScalar(Object value) => switch (value) {
    String _ => value,
    bool _ => value ? 'true' : 'false',
    _ => value.toString(),
  };

  String _encodeQueryString(Map<String, List<String>> values) {
    return values.entries
        .expand(
          (entry) => entry.value.map(
            (value) => '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(value)}',
          ),
        )
        .join('&');
  }

  String _joinPaths(String left, String right) {
    final base = left.endsWith('/') ? left.substring(0, left.length - 1) : left;
    final suffix = right.startsWith('/') ? right : '/$right';
    if (base.isEmpty || base == '/') {
      return suffix;
    }
    return '$base$suffix';
  }

  Uri _webSocketUri(Uri uri) {
    return uri.replace(
      scheme: switch (uri.scheme) {
        'https' => 'wss',
        'http' => 'ws',
        final scheme when scheme == 'ws' || scheme == 'wss' => scheme,
        final scheme => throw ArgumentError.value(
          scheme,
          'baseUri.scheme',
          'Expected http, https, ws, or wss.',
        ),
      },
    );
  }

  Uri _httpsUri(Uri uri) {
    return uri.replace(
      scheme: switch (uri.scheme) {
        'https' => 'https',
        'http' => 'https',
        final scheme => throw ArgumentError.value(
          scheme,
          'baseUri.scheme',
          'Expected http or https.',
        ),
      },
    );
  }

  bool _isJsonContentType(String value) {
    return value.toLowerCase().startsWith('application/json');
  }

  bool _isTextContentType(String value) {
    return value.toLowerCase().startsWith('text/plain');
  }

  bool _isMultipartFormDataContentType(String value) {
    return value.split(';').first.trim().toLowerCase() == 'multipart/form-data';
  }

  bool _isBinaryContentType(String value) {
    final mimeType = value.split(';').first.trim().toLowerCase();
    return mimeType == 'application/octet-stream' ||
        mimeType.startsWith('audio/') ||
        mimeType.startsWith('image/') ||
        mimeType.startsWith('video/');
  }
}

bool _isUrlEncodedContentType(String contentType) =>
    contentType.split(';').first.trim().toLowerCase() == 'application/x-www-form-urlencoded';

final _pathParameterPattern = RegExp(r'<([^>]+)>');

final class _EncodedClientRequestBody {
  const _EncodedClientRequestBody({
    required this.contentType,
    this.body,
    this.bodyStream,
    this.bodyStreamLength,
  });

  final String contentType;
  final String? body;
  final Stream<List<int>>? bodyStream;
  final int? bodyStreamLength;
}

typedef _EncodedMultipartFormData = ({
  String boundary,
  Stream<List<int>> bodyStream,
  int? bodyStreamLength,
});

_EncodedMultipartFormData _encodeMultipartFormData(MultipartFormData form) {
  final boundary = 'dart-http-boundary-${DateTime.now().microsecondsSinceEpoch}';
  return (
    boundary: boundary,
    bodyStream: _streamMultipartFormData(form, boundary),
    bodyStreamLength: _multipartFormDataContentLength(form, boundary),
  );
}

Stream<List<int>> _streamMultipartFormData(MultipartFormData form, String boundary) async* {
  final newline = utf8.encode('\r\n');
  for (final field in form.fields) {
    yield ascii.encode('--$boundary\r\n');
    yield ascii.encode(
      'Content-Disposition: form-data; '
      'name="${_escapeMultipartHeaderValue(field.name)}"\r\n\r\n',
    );
    yield utf8.encode(field.value);
    yield newline;
  }

  for (final file in form.files) {
    yield ascii.encode('--$boundary\r\n');
    yield ascii.encode(
      'Content-Disposition: form-data; '
      'name="${_escapeMultipartHeaderValue(file.fieldName)}"',
    );
    if (file.filename case final filename?) {
      yield ascii.encode('; filename="${_escapeMultipartHeaderValue(filename)}"');
    }
    yield newline;
    if (file.contentType case final contentType?) {
      yield ascii.encode('Content-Type: $contentType\r\n');
    }
    yield newline;
    yield* file.openRead();
    yield newline;
  }

  yield ascii.encode('--$boundary--\r\n');
}

int? _multipartFormDataContentLength(MultipartFormData form, String boundary) {
  var length = 0;

  int byteLength(List<int> bytes) => bytes.length;
  int asciiLength(String value) => byteLength(ascii.encode(value));
  int utf8Length(String value) => byteLength(utf8.encode(value));

  for (final field in form.fields) {
    length += asciiLength('--$boundary\r\n');
    length += asciiLength(
      'Content-Disposition: form-data; '
      'name="${_escapeMultipartHeaderValue(field.name)}"\r\n\r\n',
    );
    length += utf8Length(field.value);
    length += asciiLength('\r\n');
  }

  for (final file in form.files) {
    final fileLength = knownMultipartFileLength(file);
    if (fileLength == null) {
      return null;
    }

    length += asciiLength('--$boundary\r\n');
    length += asciiLength(
      'Content-Disposition: form-data; '
      'name="${_escapeMultipartHeaderValue(file.fieldName)}"',
    );
    if (file.filename case final filename?) {
      length += asciiLength('; filename="${_escapeMultipartHeaderValue(filename)}"');
    }
    length += asciiLength('\r\n');
    if (file.contentType case final contentType?) {
      length += asciiLength('Content-Type: $contentType\r\n');
    }
    length += asciiLength('\r\n');
    length += fileLength;
    length += asciiLength('\r\n');
  }

  length += asciiLength('--$boundary--\r\n');
  return length;
}

Stream<List<int>> _trackMultipartUploadProgress(
  Stream<List<int>> stream, {
  required int? totalBytes,
  required void Function(DartHttpMultipartUploadProgress progress)? onProgress,
}) async* {
  if (onProgress == null) {
    yield* stream;
    return;
  }

  var bytesSent = 0;
  await for (final chunk in stream) {
    bytesSent += chunk.length;
    onProgress(DartHttpMultipartUploadProgress(bytesSent: bytesSent, totalBytes: totalBytes));
    yield chunk;
  }
}

Future<void>? _combinedAbortTrigger({
  required Future<void>? abortTrigger,
  required Duration? timeout,
}) {
  final timeoutTrigger = timeout == null ? null : Future<void>.delayed(timeout);
  if (abortTrigger == null) {
    return timeoutTrigger;
  }
  if (timeoutTrigger == null) {
    return abortTrigger;
  }
  return Future.any([abortTrigger, timeoutTrigger]);
}

String _escapeMultipartHeaderValue(String value) {
  return value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
}

/// Fully described generated-client invocation.
final class DartHttpClientInvocation<TResponse, TParams, TQuery, THeaders, TBody> {
  const DartHttpClientInvocation({
    required this.method,
    required this.pathTemplate,
    required this.success,
    this.errors = const <DartHttpClientErrorSpec>[],
    this.params,
    this.query,
    this.headers,
    this.body,
    this.abortTrigger,
    this.timeout,
    this.onMultipartUploadProgress,
  });

  /// HTTP method to send.
  final HttpMethod method;

  /// Route path template using Dart HTTP parameter syntax.
  final String pathTemplate;

  /// Expected success response metadata.
  final DartHttpClientResponseSpec<TResponse> success;

  /// Documented error response metadata.
  final List<DartHttpClientErrorSpec> errors;

  /// Optional path-parameter payload.
  final DartHttpClientRequestValue<TParams>? params;

  /// Optional query payload.
  final DartHttpClientRequestValue<TQuery>? query;

  /// Optional header payload.
  final DartHttpClientRequestValue<THeaders>? headers;

  /// Optional request body payload.
  final DartHttpClientRequestBody<TBody>? body;

  /// Optional trigger that aborts the underlying HTTP request when completed.
  final Future<void>? abortTrigger;

  /// Optional timeout that aborts the underlying HTTP request when elapsed.
  final Duration? timeout;

  /// Optional progress callback for generated multipart form-data uploads.
  final void Function(DartHttpMultipartUploadProgress progress)? onMultipartUploadProgress;
}

/// Fully described generated-client WebSocket invocation.
final class DartHttpClientWebSocketInvocation<TParams, TQuery, THeaders> {
  const DartHttpClientWebSocketInvocation({
    required this.pathTemplate,
    this.params,
    this.query,
    this.headers,
    this.protocols = const <String>[],
  });

  /// Route path template using Dart HTTP parameter syntax.
  final String pathTemplate;

  /// Optional path-parameter payload.
  final DartHttpClientRequestValue<TParams>? params;

  /// Optional query payload.
  final DartHttpClientRequestValue<TQuery>? query;

  /// Optional header payload.
  final DartHttpClientRequestValue<THeaders>? headers;

  /// Optional WebSocket subprotocols.
  final List<String> protocols;
}

/// Fully described generated-client WebTransport invocation.
final class DartHttpClientWebTransportInvocation<TParams, TQuery, THeaders> {
  const DartHttpClientWebTransportInvocation({
    required this.pathTemplate,
    this.params,
    this.query,
    this.headers,
  });

  /// Route path template using Dart HTTP parameter syntax.
  final String pathTemplate;

  /// Optional path-parameter payload.
  final DartHttpClientRequestValue<TParams>? params;

  /// Optional query payload.
  final DartHttpClientRequestValue<TQuery>? query;

  /// Optional header payload.
  final DartHttpClientRequestValue<THeaders>? headers;
}

/// Schema-backed generated-client request value.
final class DartHttpClientRequestValue<T> {
  const DartHttpClientRequestValue({this.schemaId, required this.value, this.encoder});

  /// Schema id used to encode [value], when one exists.
  final String? schemaId;

  /// Request value supplied by the generated client method.
  final T value;

  /// Encodes [value] into a transport value.
  final Object? Function(T value)? encoder;

  Object? encode() {
    final encoder = this.encoder;
    if (encoder == null) {
      return value;
    }
    return encoder(value);
  }
}

/// Schema-backed generated-client request body.
final class DartHttpClientRequestBody<T> {
  const DartHttpClientRequestBody({
    required this.contentType,
    this.schemaId,
    required this.value,
    this.encoder,
  });

  /// Request body content type.
  final String contentType;

  /// Schema id used to encode [value], when one exists.
  final String? schemaId;

  /// Request body value supplied by the generated client method.
  final T value;

  /// Encodes [value] into a transport body.
  final Object? Function(T value)? encoder;

  Object? encode() {
    final encoder = this.encoder;
    if (encoder == null) {
      return value;
    }
    return encoder(value);
  }
}

/// Expected generated-client response metadata.
final class DartHttpClientResponseSpec<T> {
  const DartHttpClientResponseSpec({
    required this.status,
    required this.contentType,
    this.responseMode = DartHttpClientResponseMode.stream,
    this.schemaId,
    this.decoder,
  });

  /// Expected HTTP status code.
  final int status;

  /// Expected response content type.
  final String contentType;

  /// Expected response delivery semantics.
  final DartHttpClientResponseMode responseMode;

  /// Schema id used to decode the response body, when one exists.
  final String? schemaId;

  /// Decodes the response body into [T].
  final T Function(Object? value)? decoder;
}

/// Typed response object returned by generated HTTP clients.
final class DartHttpClientResponseObject<T> {
  const DartHttpClientResponseObject({
    required this.status,
    required this.contentType,
    this.headers = const <String, String>{},
    required this.rawBody,
    this._rawBodyBytes,
    this.data,
    this.error,
  });

  /// Actual HTTP response status.
  final int status;

  /// Actual HTTP response content type.
  final String contentType;

  /// Actual HTTP response headers.
  final Map<String, String> headers;

  /// Raw transport response body.
  final String rawBody;
  final Uint8List? _rawBodyBytes;

  /// Raw transport response body bytes.
  Uint8List get rawBodyBytes {
    final bytes = _rawBodyBytes;
    if (bytes != null) {
      return Uint8List.fromList(bytes);
    }
    return Uint8List.fromList(utf8.encode(rawBody));
  }

  /// Decoded success payload when [isSuccess] is true.
  final T? data;

  /// Decoded generic error metadata when [isSuccess] is false.
  final DartHttpClientError? error;

  /// Whether this response matched the generated success status.
  bool get isSuccess => error == null;

  /// Returns [data] or throws when the response is an error or has no data.
  T get requireData {
    if (error case final error?) {
      throw StateError(
        'Expected a successful Dart HTTP client response, got '
        '${error.status} ${error.kind.name}.',
      );
    }
    if (data case final data?) {
      return data;
    }
    throw StateError('Expected Dart HTTP client response data.');
  }
}

/// Typed response object returned by generated streaming HTTP clients.
final class DartHttpClientStreamedResponseObject {
  const DartHttpClientStreamedResponseObject({
    required this.status,
    required this.contentType,
    this.headers = const <String, String>{},
    required this.bodyStream,
    this.error,
  });

  /// Actual HTTP response status.
  final int status;

  /// Actual HTTP response content type.
  final String contentType;

  /// Actual HTTP response headers.
  final Map<String, String> headers;

  /// Raw transport response stream when [isSuccess] is true.
  final Stream<List<int>> bodyStream;

  /// Generic decoded error metadata when [isSuccess] is false.
  final DartHttpClientError? error;

  /// Whether this response matched the generated success status.
  bool get isSuccess => error == null;

  /// Response body length from the `Content-Length` header, when available.
  int? get contentLength {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() != 'content-length') {
        continue;
      }
      final value = int.tryParse(entry.value.trim());
      return value != null && value >= 0 ? value : null;
    }
    return null;
  }

  /// Returns [bodyStream] or throws when the response is an error.
  Stream<List<int>> get requireBodyStream {
    if (error case final error?) {
      throw StateError(
        'Expected a successful Dart HTTP streaming client response, got '
        '${error.status} ${error.kind.name}.',
      );
    }
    return bodyStream;
  }

  /// Returns the response body stream and reports progress as it is consumed.
  ///
  /// [totalBytes] overrides the response `Content-Length` when the caller has
  /// more accurate metadata. Progress is reported after each emitted chunk.
  Stream<List<int>> bodyStreamWithProgress({
    required void Function(DartHttpClientDownloadProgress progress) onProgress,
    int? totalBytes,
  }) async* {
    final resolvedTotalBytes = totalBytes ?? contentLength;
    var bytesReceived = 0;
    await for (final chunk in requireBodyStream) {
      bytesReceived += chunk.length;
      onProgress(
        DartHttpClientDownloadProgress(
          bytesReceived: bytesReceived,
          totalBytes: resolvedTotalBytes,
        ),
      );
      yield chunk;
    }
  }
}

/// Download progress for a streamed generated-client response body.
final class DartHttpClientDownloadProgress {
  const DartHttpClientDownloadProgress({required this.bytesReceived, required this.totalBytes});

  /// Response body bytes received from the client transport.
  final int bytesReceived;

  /// Total response body bytes, when known before downloading.
  final int? totalBytes;

  /// Completed download fraction, or `null` when [totalBytes] is unknown.
  double? get fraction {
    final totalBytes = this.totalBytes;
    if (totalBytes == null || totalBytes == 0) {
      return null;
    }
    return bytesReceived / totalBytes;
  }
}

/// Generic non-success response metadata returned by generated HTTP clients.
final class DartHttpClientError {
  const DartHttpClientError({
    required this.status,
    this.code,
    required this.kind,
    required this.contentType,
    this.headers = const <String, String>{},
    required this.rawBody,
    this._rawBodyBytes,
    this.body,
  });

  /// Actual HTTP response status.
  final int status;

  /// Documented stable error code, when this status matches route metadata.
  final String? code;

  /// Whether this error matched route metadata.
  final DartHttpClientErrorKind kind;

  /// Actual HTTP response content type.
  final String contentType;

  /// Actual HTTP response headers.
  final Map<String, String> headers;

  /// Raw transport response body.
  final String rawBody;
  final Uint8List? _rawBodyBytes;

  /// Raw transport response body bytes.
  Uint8List get rawBodyBytes {
    final bytes = _rawBodyBytes;
    if (bytes != null) {
      return Uint8List.fromList(bytes);
    }
    return Uint8List.fromList(utf8.encode(rawBody));
  }

  /// Generic decoded error body.
  final Object? body;
}

Future<Uint8List> _collectStreamBytes(Stream<List<int>> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

/// Error classification for generated HTTP client responses.
enum DartHttpClientErrorKind { documented, unknownStatus }

/// Documented error response metadata used by generated client invocations.
final class DartHttpClientErrorSpec {
  const DartHttpClientErrorSpec({required this.status, this.code});

  /// Documented HTTP error status.
  final int status;

  /// Optional stable application error code.
  final String? code;
}
