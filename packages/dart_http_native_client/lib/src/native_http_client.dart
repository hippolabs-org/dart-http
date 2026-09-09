import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dart_http_core/dart_http_core.dart';
import 'package:ffi/ffi.dart';
import 'package:native_exchange/native_exchange_ffi.dart';
import 'package:native_exchange_runtime/native_exchange_runtime.dart';

import 'generated_bindings.dart' as native;
import 'native_http_request_body.dart';
import 'native_http_response.dart';

part 'native_http_web_socket.dart';

const _nativeAbiVersion = 9;

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
  static Future<NativeHttpClientTransport> open({
    Duration? webSocketConnectTimeout,
    @Deprecated(
      'HTTP connections use NativeHttpClientRuntime.connectTimeout process-wide. '
      'Use webSocketConnectTimeout for per-transport WebSocket connections.',
    )
    Duration? connectTimeout,
    Duration requestTimeout = const Duration(minutes: 2),
    int webSocketIncomingCapacity = 16,
    int webSocketOutgoingCapacity = 8,
  }) async {
    if (webSocketConnectTimeout != null && connectTimeout != null) {
      throw ArgumentError('Specify only webSocketConnectTimeout, not legacy connectTimeout.');
    }
    final resolvedWebSocketConnectTimeout =
        webSocketConnectTimeout ?? connectTimeout ?? NativeHttpClientRuntime.connectTimeout;
    if (resolvedWebSocketConnectTimeout <= Duration.zero || requestTimeout <= Duration.zero) {
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
      requestTimeout.inMilliseconds,
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
  var _closed = false;

  /// Sends a request while preserving the response body as Native Exchange.
  Future<NativeHttpResponse> sendNative(DartHttpClientRequest request) async {
    final response = await _send(request, bufferResponse: false);
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
    final response = await _send(request, bufferResponse: true);
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
    required bool bufferResponse,
  }) async {
    _ensureOpen();
    final prepared = await _prepareRequest(request);
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
        nativeBufferTransfer?.descriptor.cast() ?? nullptr,
        nativeTransfer?.descriptor.cast() ?? nullptr,
        prepared.nativeBody?.contentLength ?? -1,
        prefixPointer,
        nativePrefix?.length ?? 0,
        suffixPointer,
        nativeSuffix?.length ?? 0,
        bufferResponse,
      );
      if (requestId <= 0) {
        nativeBufferTransfer?.close();
        nativeTransfer?.close();
        throw const NativeHttpClientException('The native HTTP request was rejected.');
      }
      nativeBufferTransfer?.markAdopted();
      nativeTransfer?.markAdopted();
      final completer = Completer<_NativeResponseData>();
      _pending[requestId] = completer;
      final abortTrigger = request.abortTrigger;
      if (abortTrigger != null) {
        unawaited(
          abortTrigger.then<void>((_) {
            if (_pending.containsKey(requestId)) {
              native.dart_http_native_client_cancel(_clientId, requestId);
            }
          }, onError: (Object _, StackTrace _) {}),
        );
      }
      final response = await completer.future;
      if (abortTrigger != null) {
        unawaited(
          abortTrigger.then<void>((_) {
            response.body?.close();
            response.bodyBuffer?.close();
          }, onError: (Object _, StackTrace _) {}),
        );
      }
      return response;
    } finally {
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
    final response = await sendNative(request);
    final reader = NativeStreamReader.adopt(response.body.takeNative());
    return DartHttpClientStreamedResponse(
      status: response.status,
      contentType: response.contentType,
      headers: response.headers,
      bodyStream: reader.copies(),
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
    native.dart_http_native_client_close(_clientId);
    unawaited(_subscription.cancel());
    _completionPort.close();
  }

  Future<_PreparedRequest> _prepareRequest(DartHttpClientRequest request) async {
    final nativeBody = request.nativeBody;
    if (nativeBody != null && nativeBody is! NativeHttpRequestBody) {
      throw ArgumentError.value(
        nativeBody,
        'request.nativeBody',
        'NativeHttpClientTransport requires NativeHttpRequestBody.',
      );
    }
    if (request.bodyStream case final bodyStream?) {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in bodyStream) {
        builder.add(chunk);
      }
      return _PreparedRequest(bytes: builder.takeBytes());
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
      final socketId = notification >> 3;
      _webSockets[socketId]?._handleNotification(kind);
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
      final bodyBuffer = value.body_buffer == nullptr
          ? null
          : NativeBufferLease.fromDescriptor(value.body_buffer.cast<NexBuffer>().ref);
      if (bodyBuffer != null) {
        value.body_buffer = nullptr;
      }
      completer.complete(
        _NativeResponseData(
          status: value.status_code,
          contentType: headers['content-type'] ?? '',
          headers: Map.unmodifiable(headers),
          body: body,
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
  const _PreparedRequest({this.bytes, this.nativeBuffer, this.nativeBody});

  final Uint8List? bytes;
  final TransferableNativeByteLease? nativeBuffer;
  final NativeHttpRequestBody? nativeBody;
}

final class _NativeResponseData {
  const _NativeResponseData({
    required this.status,
    required this.contentType,
    required this.headers,
    required this.body,
    required this.bodyBuffer,
  });

  final int status;
  final String contentType;
  final Map<String, String> headers;
  final NativeByteStreamHandle? body;
  final NativeBufferLease? bodyBuffer;
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
