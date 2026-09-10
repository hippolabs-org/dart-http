import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dart_http_core/dart_http_core.dart';
import 'package:ffi/ffi.dart';
import 'package:native_exchange/native_exchange_ffi.dart';

import 'generated_bindings.dart' as native;
import 'native_http_request_body.dart';
import 'native_http_response.dart';

part 'native_http_web_socket.dart';
part 'native_http_response_reader.dart';

const _nativeAbiVersion = 15;
const _responseModeNativeStream = 0;
const _responseModeBuffered = 1;
const _responseModeDirectStream = 2;

/// Failure reported by the asynchronous native HTTP engine.
final class NativeHttpClientException implements Exception {
  const NativeHttpClientException(this.message);

  final String message;

  @override
  String toString() => 'NativeHttpClientException: $message';
}

/// Process-wide initialization for the shared native HTTP engine.
abstract final class NativeHttpClientRuntime {
  /// Process-wide HTTP connection timeout used by the shared reqwest client.
  static const connectTimeout = Duration(seconds: 15);

  static Future<void>? _initialization;

  /// Prepares native loading, Tokio, TLS, and reqwest away from the UI isolate.
  ///
  /// Calling this is optional. [NativeHttpClientTransport.open] always awaits
  /// the same idempotent initialization before cloning an engine handle.
  static Future<void> prewarm() {
    return _initialization ??= Isolate.run(_initializeNativeEngine).then((_) {
      _ensureNativeRuntime();
    });
  }
}

/// Persistent Tokio/reqwest client implementing the Dart HTTP transport API.
final class NativeHttpClientTransport
    implements HttpClientTransport, DartHttpClientWebSocketTransport {
  NativeHttpClientTransport._(
    this._clientId,
    this._completionPort,
    this._webSocketIncomingCapacity,
    this._webSocketOutgoingCapacity,
  ) {
    _subscription = _completionPort.listen(_handleCompletion);
  }

  /// Opens a reusable native connection pool.
  ///
  /// HTTP requests have no total deadline unless [requestTimeout] is supplied.
  /// Connection establishment remains bounded by
  /// [NativeHttpClientRuntime.connectTimeout].
  static Future<NativeHttpClientTransport> open({
    Duration? webSocketConnectTimeout,
    @Deprecated(
      'HTTP connections use NativeHttpClientRuntime.connectTimeout process-wide. '
      'Use webSocketConnectTimeout for per-transport WebSocket connections.',
    )
    Duration? connectTimeout,
    Duration? requestTimeout,
    int webSocketIncomingCapacity = 16,
    int webSocketOutgoingCapacity = 8,
  }) async {
    if (webSocketConnectTimeout != null && connectTimeout != null) {
      throw ArgumentError('Specify only webSocketConnectTimeout, not legacy connectTimeout.');
    }
    final resolvedWebSocketConnectTimeout =
        webSocketConnectTimeout ?? connectTimeout ?? NativeHttpClientRuntime.connectTimeout;
    if (resolvedWebSocketConnectTimeout <= Duration.zero ||
        (requestTimeout != null && requestTimeout <= Duration.zero)) {
      throw ArgumentError('Native HTTP timeouts must be positive.');
    }
    if (webSocketIncomingCapacity < 1 ||
        webSocketIncomingCapacity > 1024 ||
        webSocketOutgoingCapacity < 1 ||
        webSocketOutgoingCapacity > 1024) {
      throw RangeError('Native WebSocket queue capacities must be between 1 and 1024.');
    }
    await NativeHttpClientRuntime.prewarm();
    final completionPort = ReceivePort();
    final clientId = native.dart_http_native_client_create(
      completionPort.sendPort.nativePort,
      resolvedWebSocketConnectTimeout.inMilliseconds,
      requestTimeout?.inMilliseconds ?? 0,
    );
    if (clientId <= 0) {
      completionPort.close();
      throw const NativeHttpClientException('Could not create the native HTTP client.');
    }
    return NativeHttpClientTransport._(
      clientId,
      completionPort,
      webSocketIncomingCapacity,
      webSocketOutgoingCapacity,
    );
  }

  final int _clientId;
  final ReceivePort _completionPort;
  final int _webSocketIncomingCapacity;
  final int _webSocketOutgoingCapacity;
  late final StreamSubscription<Object?> _subscription;
  final Map<int, Completer<_NativeResponseData>> _pending = {};
  final Map<int, NativeHttpWebSocket> _webSockets = {};
  final Map<int, _NativeHttpResponseReader> _responseReaders = {};
  var _closed = false;

  /// Sends a request while preserving the response body as Native Exchange.
  Future<NativeHttpResponse> sendNative(DartHttpClientRequest request) async {
    final response = await _send(request, responseMode: _responseModeNativeStream);
    final body = response.body;
    if (body == null) {
      throw const NativeHttpClientException('Native HTTP response had no body stream.');
    }
    return NativeHttpResponse(
      status: response.status,
      contentType: response.contentType,
      headers: response.headers,
      body: body,
    );
  }

  /// Sends a buffered request while keeping its response body native-owned.
  Future<NativeHttpBufferedResponse> sendLeased(DartHttpClientRequest request) async {
    final response = await _send(request, responseMode: _responseModeBuffered);
    final body = response.bodyBuffer;
    if (body == null) {
      throw const NativeHttpClientException('Native HTTP response had no buffered body.');
    }
    return NativeHttpBufferedResponse(
      status: response.status,
      contentType: response.contentType,
      headers: response.headers,
      body: body,
    );
  }

  Future<_NativeResponseData> _send(
    DartHttpClientRequest request, {
    required int responseMode,
  }) async {
    _ensureOpen();
    final prepared = _prepareRequest(request);
    final method = request.method.wireName.toNativeUtf8();
    final url = request.uri.toString().toNativeUtf8();
    final headers = calloc<native.NativeHttpHeader>(request.headers.length);
    final headerStrings = <Pointer<Utf8>>[];
    final bytes = prepared.bytes;
    final bodyPointer = bytes == null ? nullptr : calloc<Uint8>(bytes.length);
    final nativePrefix = prepared.nativeBody?.prefix;
    final nativeSuffix = prepared.nativeBody?.suffix;
    final prefixPointer = nativePrefix == null || nativePrefix.isEmpty
        ? nullptr
        : calloc<Uint8>(nativePrefix.length);
    final suffixPointer = nativeSuffix == null || nativeSuffix.isEmpty
        ? nullptr
        : calloc<Uint8>(nativeSuffix.length);
    NativeByteStreamTransfer? nativeTransfer;
    NativeBufferTransfer? nativeBufferTransfer;
    final upload = prepared.bodyStream == null ? null : _NativeRequestBodyUpload.open(_clientId);
    final uploadIterator = prepared.bodyStream == null
        ? null
        : StreamIterator<List<int>>(prepared.bodyStream!);
    try {
      var index = 0;
      for (final entry in request.headers.entries) {
        final name = entry.key.toNativeUtf8();
        final value = entry.value.toNativeUtf8();
        headerStrings
          ..add(name)
          ..add(value);
        headers[index]
          ..name = name.cast()
          ..value = value.cast();
        index++;
      }
      if (bytes != null && bytes.isNotEmpty) {
        bodyPointer.asTypedList(bytes.length).setAll(0, bytes);
      }
      if (nativePrefix != null && nativePrefix.isNotEmpty) {
        prefixPointer.asTypedList(nativePrefix.length).setAll(0, nativePrefix);
      }
      if (nativeSuffix != null && nativeSuffix.isNotEmpty) {
        suffixPointer.asTypedList(nativeSuffix.length).setAll(0, nativeSuffix);
      }
      if (prepared.nativeBody case final nativeBody?) {
        nativeTransfer = nativeBody.stream.takeNative();
      }
      if (prepared.nativeBuffer case final nativeBuffer?) {
        nativeBufferTransfer = nativeBuffer.takeNative();
      }
      final requestId = native.dart_http_native_client_start(
        _clientId,
        method.cast(),
        url.cast(),
        headers,
        request.headers.length,
        bodyPointer,
        bytes?.length ?? 0,
        upload?.id ?? 0,
        prepared.bodyStreamLength ?? -1,
        nativeBufferTransfer?.descriptor.cast() ?? nullptr,
        nativeTransfer?.descriptor.cast() ?? nullptr,
        prepared.nativeBody?.contentLength ?? -1,
        prefixPointer,
        nativePrefix?.length ?? 0,
        suffixPointer,
        nativeSuffix?.length ?? 0,
        request.redirectPolicy.index,
        responseMode,
      );
      if (requestId <= 0) {
        await upload?.close();
        nativeBufferTransfer?.close();
        nativeTransfer?.close();
        throw const NativeHttpClientException('The native HTTP request was rejected.');
      }
      nativeBufferTransfer?.markAdopted();
      nativeTransfer?.markAdopted();
      final completer = Completer<_NativeResponseData>();
      _pending[requestId] = completer;
      final responseFuture = completer.future;
      final uploadFuture = upload == null
          ? Future<void>.value()
          : _pumpRequestBody(uploadIterator!, upload, expectedLength: prepared.bodyStreamLength);
      final abortTrigger = request.abortTrigger;
      if (abortTrigger != null) {
        unawaited(
          abortTrigger.then<void>((_) {
            unawaited(upload?.close());
            if (_pending.containsKey(requestId)) {
              native.dart_http_native_client_cancel(_clientId, requestId);
            }
          }, onError: (Object _, StackTrace _) {}),
        );
      }
      late final _NativeResponseData response;
      try {
        final completed = await Future.wait<Object?>(<Future<Object?>>[
          responseFuture,
          uploadFuture,
        ], eagerError: true);
        response = completed.first! as _NativeResponseData;
      } on Object {
        native.dart_http_native_client_cancel(_clientId, requestId);
        await uploadIterator?.cancel();
        await upload?.close();
        rethrow;
      }
      if (abortTrigger != null) {
        unawaited(
          abortTrigger.then<void>((_) {
            response.body?.close();
            response.bodyReader?.close();
            response.bodyBuffer?.close();
          }, onError: (Object _, StackTrace _) {}),
        );
      }
      return response;
    } finally {
      await uploadIterator?.cancel();
      await upload?.close();
      calloc
        ..free(method)
        ..free(url)
        ..free(headers);
      for (final value in headerStrings) {
        calloc.free(value);
      }
      if (bodyPointer != nullptr) calloc.free(bodyPointer);
      if (prefixPointer != nullptr) calloc.free(prefixPointer);
      if (suffixPointer != nullptr) calloc.free(suffixPointer);
    }
  }

  @override
  Future<DartHttpClientResponse> send(DartHttpClientRequest request) async {
    final response = await sendLeased(request);
    return DartHttpClientResponse.leased(
      status: response.status,
      contentType: response.contentType,
      headers: response.headers,
      body: response.body,
    );
  }

  @override
  Future<DartHttpClientStreamedResponse> sendStream(DartHttpClientRequest request) async {
    final response = await sendLeasedStream(request);
    return DartHttpClientStreamedResponse(
      status: response.status,
      contentType: response.contentType,
      headers: response.headers,
      bodyStream: _copyResponseLeases(response.bodyStream),
    );
  }

  /// Sends a streamed request whose chunks remain native-owned until released.
  Future<NativeHttpLeasedStreamedResponse> sendLeasedStream(DartHttpClientRequest request) async {
    final response = await _send(request, responseMode: _responseModeDirectStream);
    final reader = response.bodyReader;
    if (reader == null) {
      throw const NativeHttpClientException('Native HTTP response had no direct body reader.');
    }
    return NativeHttpLeasedStreamedResponse(
      status: response.status,
      contentType: response.contentType,
      headers: response.headers,
      bodyStream: reader.leases(),
      closeBody: reader.close,
    );
  }

  @override
  Future<DartHttpClientWebSocket> connect(DartHttpClientWebSocketRequest request) =>
      _connectWebSocket(request);

  /// Cancels in-flight work and closes the native connection pool.
  void close() {
    if (_closed) return;
    _closed = true;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(const NativeHttpClientException('Native HTTP client closed.'));
      }
    }
    _pending.clear();
    for (final socket in _webSockets.values.toList()) {
      socket._transportClosed();
    }
    _webSockets.clear();
    for (final reader in _responseReaders.values.toList()) {
      reader._transportClosed();
    }
    _responseReaders.clear();
    native.dart_http_native_client_close(_clientId);
    unawaited(_subscription.cancel());
    _completionPort.close();
  }

  _PreparedRequest _prepareRequest(DartHttpClientRequest request) {
    final nativeBody = request.nativeBody;
    if (nativeBody != null && nativeBody is! NativeHttpRequestBody) {
      throw ArgumentError.value(
        nativeBody,
        'request.nativeBody',
        'NativeHttpClientTransport requires NativeHttpRequestBody.',
      );
    }
    if (request.bodyStream case final bodyStream?) {
      final length = request.bodyStreamLength;
      if (length != null && length < 0) {
        throw RangeError.value(length, 'request.bodyStreamLength', 'Length must not be negative.');
      }
      return _PreparedRequest(bodyStream: bodyStream, bodyStreamLength: length);
    }
    if (request.bodyLease case final bodyLease?) {
      if (bodyLease is TransferableNativeByteLease) {
        return _PreparedRequest(nativeBuffer: bodyLease);
      }
      return _PreparedRequest(bytes: bodyLease.takeDartBytes());
    }
    if (request.bodyBytes case final bodyBytes?) {
      return _PreparedRequest(
        bytes: bodyBytes is Uint8List ? bodyBytes : Uint8List.fromList(bodyBytes),
      );
    }
    if (request.body case final body?) {
      return _PreparedRequest(bytes: utf8.encode(body));
    }
    return _PreparedRequest(nativeBody: nativeBody as NativeHttpRequestBody?);
  }

  void _handleCompletion(Object? message) {
    if (message is! int) return;
    if (message < 0) {
      final notification = -message;
      final kind = notification & 7;
      final resourceId = notification >> 3;
      if (kind == _responseReaderEventReady) {
        _responseReaders[resourceId]?._handleNotification();
      } else {
        _webSockets[resourceId]?._handleNotification(kind);
      }
      return;
    }
    final completer = _pending.remove(message);
    if (completer == null) return;
    final result = native.dart_http_native_client_take_result(_clientId, message);
    if (result == nullptr) {
      completer.completeError(
        const NativeHttpClientException('Native HTTP result was unavailable.'),
      );
      return;
    }
    try {
      final value = result.ref;
      if (!value.success) {
        completer.completeError(
          NativeHttpClientException(_readCString(value.error) ?? 'Native HTTP request failed.'),
        );
        return;
      }
      final headers = <String, String>{};
      if (value.header_count < 0 || (value.header_count > 0 && value.headers == nullptr)) {
        throw const NativeHttpClientException('Native HTTP response headers were invalid.');
      }
      for (var index = 0; index < value.header_count; index++) {
        final header = (value.headers + index).ref;
        final name = _readCString(header.name);
        final headerValue = _readCString(header.value);
        if (name != null && headerValue != null) {
          headers[name.toLowerCase()] = headerValue;
        }
      }
      final body = value.body_stream == nullptr
          ? null
          : NativeByteStreamHandle.fromDescriptor(value.body_stream.cast<NexByteStream>().ref);
      NativeBufferLease? bodyBuffer;
      if (value.body_buffer != nullptr) {
        final descriptor = calloc<NexBuffer>();
        final transferred = native.dart_http_native_client_result_take_body_buffer(
          result,
          descriptor.cast(),
        );
        if (!transferred) {
          calloc.free(descriptor);
          throw const NativeHttpClientException(
            'Native HTTP response body ownership could not be transferred.',
          );
        }
        bodyBuffer = NativeBufferLease.fromPointer(descriptor);
      }
      final bodyReader = value.body_reader == nullptr
          ? null
          : _NativeHttpResponseReader.adopt(
              transport: this,
              readerId: value.body_reader_id,
              reader: value.body_reader,
            );
      if (bodyReader != null) {
        value.body_reader = nullptr;
        _responseReaders[value.body_reader_id] = bodyReader;
      }
      completer.complete(
        _NativeResponseData(
          status: value.status_code,
          contentType: headers['content-type'] ?? '',
          headers: Map.unmodifiable(headers),
          body: body,
          bodyReader: bodyReader,
          bodyBuffer: bodyBuffer,
        ),
      );
    } catch (error, stackTrace) {
      completer.completeError(error, stackTrace);
    } finally {
      native.dart_http_native_client_free_result(result);
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('NativeHttpClientTransport is closed.');
  }
}

final class _PreparedRequest {
  const _PreparedRequest({
    this.bytes,
    this.nativeBuffer,
    this.nativeBody,
    this.bodyStream,
    this.bodyStreamLength,
  });

  final Uint8List? bytes;
  final TransferableNativeByteLease? nativeBuffer;
  final NativeHttpRequestBody? nativeBody;
  final Stream<List<int>>? bodyStream;
  final int? bodyStreamLength;
}

final class _NativeRequestBodyUpload {
  _NativeRequestBodyUpload._(this.clientId, this.id, this._completionPort) {
    _subscription = _completionPort.listen(_handleCompletion);
  }

  factory _NativeRequestBodyUpload.open(int clientId) {
    final completionPort = ReceivePort();
    final id = native.dart_http_native_client_upload_create(
      clientId,
      completionPort.sendPort.nativePort,
      1,
    );
    if (id <= 0) {
      completionPort.close();
      throw const NativeHttpClientException('Could not create a native streaming upload.');
    }
    return _NativeRequestBodyUpload._(clientId, id, completionPort);
  }

  final int clientId;
  final int id;
  final ReceivePort _completionPort;
  late final StreamSubscription<Object?> _subscription;
  final Map<int, Completer<void>> _pending = <int, Completer<void>>{};
  var _nextWriteId = 1;
  Future<void>? _closeFuture;

  Future<void>? write(List<int> chunk) {
    if (_closeFuture != null) {
      throw const NativeHttpClientException('Native streaming upload is closed.');
    }
    if (chunk.isEmpty) return null;
    final pointer = native.dart_http_native_client_upload_chunk_allocate(chunk.length);
    if (pointer == nullptr) {
      throw const NativeHttpClientException('Could not allocate a native streaming upload chunk.');
    }
    pointer.asTypedList(chunk.length).setAll(0, chunk);
    final writeId = _nextWriteId++;
    final status = native.dart_http_native_client_upload_write(
      clientId,
      id,
      writeId,
      pointer,
      chunk.length,
    );
    if (status < 0) {
      throw const NativeHttpClientException('Native streaming upload rejected a chunk.');
    }
    if (status > 0) return null;
    final completion = Completer<void>();
    _pending[writeId] = completion;
    return completion.future;
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    native.dart_http_native_client_upload_close(clientId, id);
    for (final completion in _pending.values) {
      if (!completion.isCompleted) {
        completion.completeError(
          const NativeHttpClientException('Native streaming upload closed.'),
        );
      }
    }
    _pending.clear();
    await _subscription.cancel();
    _completionPort.close();
  }

  void _handleCompletion(Object? message) {
    if (message is! int || message == 0) return;
    final completion = _pending.remove(message.abs());
    if (completion == null || completion.isCompleted) return;
    if (message > 0) {
      completion.complete();
    } else {
      completion.completeError(
        const NativeHttpClientException('Native streaming upload receiver closed.'),
      );
    }
  }
}

Future<void> _pumpRequestBody(
  StreamIterator<List<int>> iterator,
  _NativeRequestBodyUpload upload, {
  required int? expectedLength,
}) async {
  var sent = 0;
  try {
    while (await iterator.moveNext()) {
      final chunk = iterator.current;
      if (expectedLength != null && sent + chunk.length > expectedLength) {
        throw StateError(
          'Request body stream exceeded its declared length of '
          '$expectedLength bytes.',
        );
      }
      final backpressure = upload.write(chunk);
      if (backpressure != null) await backpressure;
      sent += chunk.length;
    }
    if (expectedLength != null && sent != expectedLength) {
      throw StateError(
        'Request body stream produced $sent bytes, but declared '
        '$expectedLength bytes.',
      );
    }
  } finally {
    await upload.close();
  }
}

final class _NativeResponseData {
  const _NativeResponseData({
    required this.status,
    required this.contentType,
    required this.headers,
    required this.body,
    required this.bodyReader,
    required this.bodyBuffer,
  });

  final int status;
  final String contentType;
  final Map<String, String> headers;
  final NativeByteStreamHandle? body;
  final _NativeHttpResponseReader? bodyReader;
  final NativeBufferLease? bodyBuffer;
}

Stream<Uint8List> _copyResponseLeases(Stream<NativeBufferLease> leases) async* {
  await for (final lease in leases) {
    try {
      yield lease.copyBytes();
    } finally {
      lease.close();
    }
  }
}

bool _nativeInitialized = false;

void _ensureNativeRuntime() {
  if (!_nativeInitialized) {
    final status = native.dart_http_native_client_initialize_api_dl(NativeApi.initializeApiDLData);
    if (status != 0) {
      throw const NativeHttpClientException('Could not initialize the Dart native API.');
    }
    _nativeInitialized = true;
  }
  if (native.dart_http_native_client_abi_version() != _nativeAbiVersion) {
    throw const NativeHttpClientException('Native HTTP ABI version mismatch.');
  }
}

void _initializeNativeEngine() {
  _ensureNativeRuntime();
  if (native.dart_http_native_client_engine_initialize() != 0) {
    throw const NativeHttpClientException('Could not initialize the native HTTP engine.');
  }
}

String? _readCString(Pointer<Char> value) =>
    value == nullptr ? null : value.cast<Utf8>().toDartString();
