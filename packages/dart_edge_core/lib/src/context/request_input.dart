/// Holds decoded request input values for a route handler.
final class RequestInput {
  factory RequestInput({
    Object? params,
    Object? query,
    Object? headers,
    Object? body,
    Map<String, String>? paramsMap,
    Map<String, String>? queryMap,
    Map<String, String>? headersMap,
    Future<Object?> Function()? multipartLoader,
    Object? nativeBody,
  }) {
    final normalizedParamsMap = _normalizedStringMap(paramsMap, params);
    final normalizedQueryMap = _normalizedStringMap(queryMap, query);
    final normalizedHeadersMap = _normalizedStringMap(headersMap, headers);

    return RequestInput._(
      paramsValue: params,
      queryValue: query,
      headerValue: headers,
      bodyValue: body,
      paramsMap: normalizedParamsMap,
      queryMap: normalizedQueryMap,
      headersMap: normalizedHeadersMap,
      multipartLoader: multipartLoader,
      nativeBody: nativeBody,
    );
  }

  const RequestInput._({
    this._paramsValue,
    this._queryValue,
    this._headerValue,
    this._bodyValue,
    this.paramsMap = const <String, String>{},
    this.queryMap = const <String, String>{},
    this.headersMap = const <String, String>{},
    this._multipartLoader,
    this._nativeBody,
  });

  static const empty = RequestInput._();

  final Future<Object?> Function()? _multipartLoader;
  final Object? _paramsValue;
  final Object? _queryValue;
  final Object? _headerValue;
  final Object? _bodyValue;
  final Object? _nativeBody;

  /// Raw path parameters as strings.
  final Map<String, String> paramsMap;

  /// Raw query parameters as strings.
  final Map<String, String> queryMap;

  /// Raw request headers as strings.
  final Map<String, String> headersMap;

  /// Returns one path parameter by [name], if present.
  String? param(String name) => paramsMap[name];

  /// Returns one query parameter by [name], if present.
  String? queryParam(String name) => queryMap[name];

  /// Returns one header by [name], if present.
  ///
  /// Header names are matched case-insensitively.
  String? header(String name) => headersMap[name.toLowerCase()];

  /// Whether a decoded path parameter object of type [T] is available.
  bool hasParams<T>() => _paramsValue is T;

  /// Whether a decoded query object of type [T] is available.
  bool hasQuery<T>() => _queryValue is T;

  /// Whether a decoded header object of type [T] is available.
  bool hasHeaders<T>() => _headerValue is T;

  /// Whether a decoded request body of type [T] is available.
  bool hasBody<T>() => _bodyValue is T;

  /// Reads the path parameters as [T].
  T params<T>() => _read<T>(_paramsValue, 'params');

  /// Reads the path parameters as [T], or `null` when absent.
  T? maybeParams<T>() => _maybeRead<T>(_paramsValue);

  /// Reads the query payload as [T].
  T query<T>() => _read<T>(_queryValue, 'query');

  /// Reads the query payload as [T], or `null` when absent.
  T? maybeQuery<T>() => _maybeRead<T>(_queryValue);

  /// Reads the header payload as [T].
  T headers<T>() => _read<T>(_headerValue, 'headers');

  /// Reads the header payload as [T], or `null` when absent.
  T? maybeHeaders<T>() => _maybeRead<T>(_headerValue);

  /// Reads the request body as [T].
  T body<T>() => _read<T>(_bodyValue, 'body');

  /// Reads the request body as [T], or `null` when absent.
  T? maybeBody<T>() => _maybeRead<T>(_bodyValue);

  /// Decoded request body when you need the raw value without a cast.
  Object? get bodyOrNull => _bodyValue;

  /// Runtime-specific native body view when one is available.
  ///
  /// Use a runtime package extension, such as `ctx.req.nativeBody`, for a
  /// strongly typed view.
  Object? get nativeBodyOrNull => _nativeBody;

  /// Reads the runtime-specific native body as [T], or `null` when absent.
  T? maybeNativeBody<T>() => _maybeRead<T>(_nativeBody);

  /// Whether this request exposes multipart form-data parsing.
  bool get hasMultipart => _multipartLoader != null;

  /// Loads the multipart form-data payload as [T].
  Future<T> multipartValue<T>() async {
    final loader = _multipartLoader;
    if (loader == null) {
      throw StateError('No multipart value is available.');
    }

    final value = await loader();
    if (value is T) {
      return value;
    }

    throw StateError('No multipart value of type $T is available.');
  }

  static T _read<T>(Object? value, String label) {
    if (value is T) {
      return value;
    }

    throw StateError('No $label value of type $T is available.');
  }

  static T? _maybeRead<T>(Object? value) => value is T ? value : null;

  static Map<String, String> _normalizedStringMap(
    Map<String, String>? explicitValue,
    Object? fallbackValue,
  ) {
    if (explicitValue case final explicit?) {
      return Map<String, String>.unmodifiable(explicit);
    }
    if (fallbackValue case final Map<String, String> map) {
      return Map<String, String>.unmodifiable(map);
    }
    return const <String, String>{};
  }
}
