import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_http_server/dart_http_server.dart' as dart_http;
import 'package:dart_mcp/server.dart';
import 'package:dart_mcp/streamable_http.dart';

/// Creates the request-scoped MCP server factory for one Dart HTTP request.
///
/// This lets applications read authenticated values installed by route guards
/// and inject request-scoped services into each MCP server instance.
typedef DartHttpMcpServerFactory<TServices> = MCPServerFactory Function(
  dart_http.RequestContext<TServices> context,
);

/// Receives a server-side failure after the MCP response has been completed.
typedef DartHttpMcpErrorHandler = void Function(Object error, StackTrace stackTrace);

/// Mounts a `dart_mcp` Streamable HTTP endpoint on a Dart HTTP [Router].
extension DartHttpMcpRouter<TServices> on dart_http.Router<TServices> {
  void mountMcp(
    String path, {
    required DartHttpMcpServerFactory<TServices> serverFactory,
    List<dart_http.Guard<TServices>> guards = const [],
    Set<String>? allowedOrigins,
    Stream<Map<String, Object?>>? subscriptionNotifications,
    void Function(Map<String, Object?> notification)? onNotification,
    DartHttpMcpErrorHandler? onError,
    Duration keepAliveInterval = const Duration(seconds: 15),
    int maxRequestBodyBytes = 4 * 1024 * 1024,
  }) {
    if (maxRequestBodyBytes < 0) {
      throw RangeError.value(maxRequestBodyBytes, 'maxRequestBodyBytes', 'Must not be negative.');
    }

    post<Object>(
      path,
      options: dart_http.RouteOptions(
        operationId: _operationId(path),
        exposure: dart_http.RouteExposure.internal,
        success: const dart_http.ResponseSpec.binary(),
      ),
      guards: guards,
      handler: (context) => _handleMcpRequest(
        context,
        serverFactory: serverFactory(context),
        allowedOrigins: allowedOrigins,
        subscriptionNotifications: subscriptionNotifications,
        onNotification: onNotification,
        onError: onError,
        keepAliveInterval: keepAliveInterval,
        maxRequestBodyBytes: maxRequestBodyBytes,
      ),
    );

    Object methodNotAllowed(dart_http.RequestContext<TServices> _) => const dart_http.RawResponse(
      status: HttpStatus.methodNotAllowed,
      contentType: 'application/octet-stream',
      headers: <dart_http.HttpHeader>[dart_http.HttpHeader(HttpHeaders.allowHeader, 'POST')],
      isEncodedBody: true,
    );

    final rejectedOptions = dart_http.RouteOptions(
      operationId: '${_operationId(path)}MethodNotAllowed',
      exposure: dart_http.RouteExposure.internal,
      success: const dart_http.ResponseSpec.binary(status: HttpStatus.methodNotAllowed),
    );
    get<Object>(path, options: rejectedOptions, handler: methodNotAllowed);
    put<Object>(path, options: rejectedOptions, handler: methodNotAllowed);
    patch<Object>(path, options: rejectedOptions, handler: methodNotAllowed);
    delete<Object>(path, options: rejectedOptions, handler: methodNotAllowed);
  }
}

Future<Object> _handleMcpRequest<TServices>(
  dart_http.RequestContext<TServices> context, {
  required MCPServerFactory serverFactory,
  required Set<String>? allowedOrigins,
  required Stream<Map<String, Object?>>? subscriptionNotifications,
  required void Function(Map<String, Object?> notification)? onNotification,
  required DartHttpMcpErrorHandler? onError,
  required Duration keepAliveInterval,
  required int maxRequestBodyBytes,
}) async {
  final body = context.req.nativeBody?.copyBytes() ?? _fallbackBody(context.req.bodyOrNull);
  final response = _DartHttpBackedResponse();
  final request = _DartHttpBackedRequest(
    headers: context.req.headersMap,
    body: body,
    response: response,
  );

  final handling = handleStreamableHttpRequest(
    request,
    serverFactory,
    allowedOrigins: allowedOrigins,
    subscriptionNotifications: subscriptionNotifications,
    onNotification: onNotification,
    keepAliveInterval: keepAliveInterval,
    maxRequestBodyBytes: maxRequestBodyBytes,
  );
  response.track(handling, onError: onError);

  final result = await response.ready;
  return switch (result) {
    _BufferedResponse() => dart_http.RawResponse.binary(
      status: result.status,
      contentType: result.contentType,
      body: result.body,
      headers: result.headers,
    ),
    _StreamingResponse() => dart_http.BinaryStreamResponse(
      status: result.status,
      contentType: result.contentType,
      body: result.body,
      headers: result.headers,
      onDispose: response.disconnect,
    ),
  };
}

Uint8List _fallbackBody(Object? body) => switch (body) {
  null => Uint8List(0),
  Uint8List() => body,
  List<int>() => Uint8List.fromList(body),
  String() => Uint8List.fromList(utf8.encode(body)),
  _ => Uint8List.fromList(utf8.encode(jsonEncode(body))),
};

String _operationId(String path) {
  final words = path.split(RegExp('[^A-Za-z0-9]+')).where((word) => word.isNotEmpty).toList();
  if (words.isEmpty) return 'mcpStreamableHttp';
  return 'mcp${words.map((word) => '${word[0].toUpperCase()}${word.substring(1)}').join()}';
}

sealed class _ResponseResult {
  const _ResponseResult({required this.status, required this.contentType, required this.headers});

  final int status;
  final String contentType;
  final List<dart_http.HttpHeader> headers;
}

final class _BufferedResponse extends _ResponseResult {
  const _BufferedResponse({
    required super.status,
    required super.contentType,
    required super.headers,
    required this.body,
  });

  final Uint8List body;
}

final class _StreamingResponse extends _ResponseResult {
  const _StreamingResponse({
    required super.status,
    required super.contentType,
    required super.headers,
    required this.body,
  });

  final Stream<List<int>> body;
}

final class _DartHttpBackedRequest extends Stream<Uint8List> implements HttpRequest {
  _DartHttpBackedRequest({
    required Map<String, String> headers,
    required Uint8List body,
    required this.response,
  }) : headers = _MemoryHttpHeaders.fromSingleValues(headers),
       _body = Stream<Uint8List>.value(body);

  final Stream<Uint8List> _body;

  @override
  final HttpHeaders headers;

  @override
  final HttpResponse response;

  @override
  String get method => 'POST';

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _body.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _DartHttpBackedResponse implements HttpResponse {
  final _headers = _MemoryHttpHeaders();
  final _body = BytesBuilder(copy: false);
  final _stream = StreamController<List<int>>();
  final _ready = Completer<_ResponseResult>();
  final _done = Completer<void>();
  var _streaming = false;
  var _closed = false;

  @override
  int statusCode = HttpStatus.ok;

  @override
  int contentLength = -1;

  @override
  bool bufferOutput = true;

  @override
  HttpHeaders get headers => _headers;

  Future<_ResponseResult> get ready => _ready.future;

  @override
  Future<void> get done => _done.future;

  void track(Future<void> handling, {DartHttpMcpErrorHandler? onError}) {
    unawaited(
      handling.catchError((Object error, StackTrace stackTrace) async {
        onError?.call(error, stackTrace);
        if (!_closed) {
          _stream.addError(error, stackTrace);
          await close();
        }
      }),
    );
  }

  @override
  void write(Object? object) {
    if (_closed) return;
    final bytes = utf8.encode(object?.toString() ?? 'null');
    if (_isEventStream) {
      _startStreaming();
      _stream.add(bytes);
    } else {
      _body.add(bytes);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_streaming) {
      await _stream.close();
    } else if (!_ready.isCompleted) {
      _ready.complete(
        _BufferedResponse(
          status: statusCode,
          contentType: _contentType,
          headers: _responseHeaders,
          body: _body.takeBytes(),
        ),
      );
    }
    if (!_done.isCompleted) _done.complete();
  }

  Future<void> disconnect() async {
    if (!_done.isCompleted) _done.complete();
    if (!_closed) {
      _closed = true;
      await _stream.close();
    }
  }

  void _startStreaming() {
    if (_streaming) return;
    _streaming = true;
    _ready.complete(
      _StreamingResponse(
        status: statusCode,
        contentType: _contentType,
        headers: _responseHeaders,
        body: _stream.stream,
      ),
    );
  }

  bool get _isEventStream => _headers.contentType?.mimeType == 'text/event-stream';

  String get _contentType => _headers.contentType?.toString() ?? 'application/octet-stream';

  List<dart_http.HttpHeader> get _responseHeaders => _headers.entries
      .where((entry) => entry.key != HttpHeaders.contentTypeHeader)
      .expand((entry) => entry.value.map((value) => dart_http.HttpHeader(entry.key, value)))
      .toList(growable: false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _MemoryHttpHeaders implements HttpHeaders {
  _MemoryHttpHeaders();

  factory _MemoryHttpHeaders.fromSingleValues(Map<String, String> values) {
    final headers = _MemoryHttpHeaders();
    for (final entry in values.entries) {
      headers.set(entry.key, entry.value);
    }
    return headers;
  }

  final Map<String, List<String>> _values = <String, List<String>>{};

  Iterable<MapEntry<String, List<String>>> get entries => _values.entries;

  @override
  List<String>? operator [](String name) => _values[name.toLowerCase()];

  @override
  String? value(String name) {
    final values = this[name];
    if (values == null || values.isEmpty) return null;
    if (values.length != 1) {
      throw HttpException('More than one value for header $name');
    }
    return values.single;
  }

  @override
  ContentType? get contentType {
    final raw = value(HttpHeaders.contentTypeHeader);
    return raw == null ? null : ContentType.parse(raw);
  }

  @override
  set contentType(ContentType? value) {
    if (value == null) {
      removeAll(HttpHeaders.contentTypeHeader);
    } else {
      set(HttpHeaders.contentTypeHeader, value.toString());
    }
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = <String>[value.toString()];
  }

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _values.putIfAbsent(name.toLowerCase(), () => <String>[]).add(value.toString());
  }

  @override
  void removeAll(String name) {
    _values.remove(name.toLowerCase());
  }

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _values.forEach(action);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
