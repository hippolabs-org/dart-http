import 'dart:async';
import 'dart:collection';
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

const _nativeAbiVersion = 19;
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
    this._webSocketCloseTimeout,
  ) {
    _subscription = _completionPort.listen(_handleCompletion);
  }

  /// Opens a reusable native connection pool.
  ///
  /// HTTP requests have no total deadline unless [requestTimeout] is supplied.
  /// Connection establishment remains bounded by
  /// [NativeHttpClientRuntime.connectTimeout].
  ///
  /// A WebSocket whose peer does not answer `close()` within
  /// [webSocketCloseTimeout] is torn down, as `dart:io` does.
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
    Duration webSocketCloseTimeout = const Duration(seconds: 5),
  }) async {
    if (webSocketConnectTimeout != null && connectTimeout != null) {
      throw ArgumentError('Specify only webSocketConnectTimeout, not legacy connectTimeout.');
    }
    final resolvedWebSocketConnectTimeout =
        webSocketConnectTimeout ?? connectTimeout ?? NativeHttpClientRuntime.connectTimeout;
    if (resolvedWebSocketConnectTimeout <= Duration.zero ||
        (requestTimeout != null && requestTimeout <= Duration.zero) ||
        webSocketCloseTimeout <= Duration.zero) {
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
      webSocketCloseTimeout,
    );
  }

  final int _clientId;
  final ReceivePort _completionPort;
  final int _webSocketIncomingCapacity;
  final int _webSocketOutgoingCapacity;
  final Duration _webSocketCloseTimeout;
  late final StreamSubscription<Object?> _subscription;
  final Map<int, Completer<_NativeResponseData>> _pending = {};
  final Map<int, NativeHttpWebSocket> _webSockets = {};
  final Map<int, _NativeHttpResponseReaderEntry> _responseReaders = {};
  var _closed = false;

  /// Number of streamed response bodies whose native reader is still open.
  ///
  /// Exposed for leak tests only.
  int get debugOpenResponseReaderCount => _responseReaders.length;

  /// Number of streamed response bodies the transport keeps reachable. Only
  /// bodies that are being read are held strongly; an unlistened body can be
  /// garbage collected and its native reader finalized.
  ///
  /// Exposed for leak tests only.
  int get debugStronglyHeldResponseReaderCount =>
      _responseReaders.values.where((entry) => entry.active != null).length;

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
    final progressDone = Completer<void>();
    var lastProgress = -1;
    final totalBytes =
        prepared.bodyStreamLength ??
        prepared.nativeBody?.contentLength ??
        prepared.nativeBuffer?.length ??
        prepared.bytes?.length;
    final bytes = prepared.bytes;
    final nativePrefix = prepared.nativeBody?.prefix;
    final nativeSuffix = prepared.nativeBody?.suffix;
    // Everything below is released in the finally block, so a failure while
    // setting the request up cannot leak a port or native memory.
    ReceivePort? progressPort;
    StreamSubscription<Object?>? progressSubscription;
    Pointer<Utf8> method = nullptr;
    Pointer<Utf8> url = nullptr;
    Pointer<native.NativeHttpHeader> headers = nullptr;
    final headerStrings = <Pointer<Utf8>>[];
    Pointer<Uint8> bodyPointer = nullptr;
    Pointer<Uint8> prefixPointer = nullptr;
    Pointer<Uint8> suffixPointer = nullptr;
    NativeByteStreamTransfer? nativeTransfer;
    NativeBufferTransfer? nativeBufferTransfer;
    _NativeRequestBodyUpload? upload;
    StreamIterator<List<int>>? uploadIterator;
    try {
      if (request.onUploadProgress case final onUploadProgress?) {
        progressPort = ReceivePort();
        progressSubscription = progressPort.listen((message) {
          if (message is! int) return;
          if (message == -1) {
            if (!progressDone.isCompleted) progressDone.complete();
          } else if (message > lastProgress) {
            lastProgress = message;
            onUploadProgress(
              DartHttpClientUploadProgress(
                bytes: message,
                totalBytes: totalBytes,
                measurement: DartHttpClientUploadMeasurement.transportConsumed,
              ),
            );
          }
        });
      }
      method = request.method.wireName.toNativeUtf8();
      url = request.uri.toString().toNativeUtf8();
      headers = calloc<native.NativeHttpHeader>(request.headers.length);
      if (nativePrefix != null && nativePrefix.isNotEmpty) {
        prefixPointer = calloc<Uint8>(nativePrefix.length);
      }
      if (nativeSuffix != null && nativeSuffix.isNotEmpty) {
        suffixPointer = calloc<Uint8>(nativeSuffix.length);
      }
      if (prepared.bodyStream case final bodyStream?) {
        upload = _NativeRequestBodyUpload.open(_clientId);
        uploadIterator = StreamIterator<List<int>>(bodyStream);
      }
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
      final bodyLength = bytes?.length ?? 0;
      if (bytes != null && bytes.isNotEmpty) {
        bodyPointer = _copyToNativeBytes(bytes);
      }
      // The only Dart copy of a leased body has been made; release it now.
      prepared.copiedLease?.close();
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
        bodyLength,
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
        progressPort?.sendPort.nativePort ?? 0,
      );
      // The native call adopted the body allocation on every return path.
      bodyPointer = nullptr;
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
        final abortedUpload = upload;
        unawaited(
          abortTrigger.then<void>((_) {
            unawaited(abortedUpload?.close());
            if (_pending.containsKey(requestId)) {
              native.dart_http_native_client_cancel(_clientId, requestId);
            }
          }, onError: (Object _, StackTrace _) {}),
        );
      }
      late final _NativeResponseData response;
      try {
        response = await _awaitResponseAndUpload(responseFuture, uploadFuture);
        if (progressPort != null) await progressDone.future;
      } on Object {
        native.dart_http_native_client_cancel(_clientId, requestId);
        await uploadIterator?.cancel();
        await upload?.close();
        rethrow;
      }
      if (abortTrigger != null) {
        // Weak, so an abort trigger that never fires does not keep an
        // unlistened response body (and its native reader) alive.
        final abortedResponse = WeakReference(response);
        unawaited(
          abortTrigger.then<void>((_) {
            final response = abortedResponse.target;
            if (response == null) return;
            response.body?.close();
            unawaited(
              response.bodyReader?.abort(
                const NativeHttpClientException(
                  'Native HTTP response body was aborted before it completed.',
                ),
              ),
            );
            response.bodyBuffer?.close();
          }, onError: (Object _, StackTrace _) {}),
        );
      }
      return response;
    } finally {
      await progressSubscription?.cancel();
      progressPort?.close();
      await uploadIterator?.cancel();
      await upload?.close();
      if (method != nullptr) calloc.free(method);
      if (url != nullptr) calloc.free(url);
      if (headers != nullptr) calloc.free(headers);
      for (final value in headerStrings) {
        calloc.free(value);
      }
      prepared.copiedLease?.close();
      if (bodyPointer != nullptr) {
        native.dart_http_native_client_bytes_free(bodyPointer, prepared.bytes?.length ?? 0);
      }
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
      body: _NativeResponseBodyLease(response.body),
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
    for (final entry in _responseReaders.values.toList()) {
      final reader = entry.active ?? entry.reader.target;
      if (reader != null) {
        reader._transportClosed();
      } else {
        entry.resources.release();
      }
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
      // Copied straight from the lease view into native memory, then closed.
      return _PreparedRequest(bytes: bodyLease.bytesView, copiedLease: bodyLease);
    }
    if (request.bodyBytes case final bodyBytes?) {
      // Any List<int> is written straight into native memory: one copy.
      return _PreparedRequest(bytes: bodyBytes);
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
        _responseReaders[resourceId]?.active?._handleNotification();
      } else {
        _webSockets[resourceId]?._handleNotification(kind);
      }
      return;
    }
    final completer = _pending.remove(message);
    final result = native.dart_http_native_client_take_result(_clientId, message);
    if (completer == null) {
      // Nobody waits for this request any more; release what it produced.
      _discardOrphanedResult(result);
      return;
    }
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
          _addResponseHeader(headers, name.toLowerCase(), headerValue);
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
        _responseReaders[value.body_reader_id] = _NativeHttpResponseReaderEntry(bodyReader);
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

  void _discardOrphanedResult(Pointer<native.NativeHttpResult> result) {
    if (result == nullptr) return;
    try {
      final value = result.ref;
      if (value.success && value.body_stream != nullptr) {
        // The descriptor box is freed with the result; the stream it describes
        // is owned by whoever adopts the descriptor.
        NativeByteStreamHandle.fromDescriptor(value.body_stream.cast<NexByteStream>().ref).close();
      }
    } finally {
      native.dart_http_native_client_free_result(result);
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('NativeHttpClientTransport is closed.');
  }
}

/// Transport bookkeeping for one streamed response body.
///
/// The reader is held weakly until its body is listened to, so an unlistened
/// response can be garbage collected and its native reader released by the
/// finalizer. [resources] lets [NativeHttpClientTransport.close] release the
/// native reader even after the Dart reader is gone.
final class _NativeHttpResponseReaderEntry {
  _NativeHttpResponseReaderEntry(_NativeHttpResponseReader reader)
    : reader = WeakReference(reader),
      resources = reader._resources;

  final WeakReference<_NativeHttpResponseReader> reader;
  final _NativeHttpResponseReaderResources resources;

  /// Strong reference while the body is being read; native readiness
  /// notifications must reach the reader even when nothing else holds it.
  _NativeHttpResponseReader? active;
}

final class _PreparedRequest {
  const _PreparedRequest({
    this.bytes,
    this.copiedLease,
    this.nativeBuffer,
    this.nativeBody,
    this.bodyStream,
    this.bodyStreamLength,
  });

  final List<int>? bytes;

  /// A non-transferable lease whose view is [bytes]; closed once copied.
  final ByteLease? copiedLease;
  final TransferableNativeByteLease? nativeBuffer;
  final NativeHttpRequestBody? nativeBody;
  final Stream<List<int>>? bodyStream;
  final int? bodyStreamLength;
}

/// Copies [bytes] into an uninitialized Rust allocation that a native call
/// then adopts without another copy. Callers must hand the pointer to such a
/// call or free it with `dart_http_native_client_bytes_free`.
Pointer<Uint8> _copyToNativeBytes(List<int> bytes) {
  final pointer = native.dart_http_native_client_bytes_allocate(bytes.length);
  if (pointer == nullptr) {
    throw const NativeHttpClientException('Could not allocate native request bytes.');
  }
  pointer.asTypedList(bytes.length).setRange(0, bytes.length, bytes);
  return pointer;
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
    final pointer = _copyToNativeBytes(chunk);
    final writeId = _nextWriteId++;
    final status = native.dart_http_native_client_upload_write(
      clientId,
      id,
      writeId,
      pointer,
      chunk.length,
    );
    if (status < 0) {
      // The native side rejects chunks once the request stopped reading its
      // body (receiver dropped or upload already removed).
      throw const _NativeUploadReceiverClosedException(
        'Native streaming upload rejected a chunk because its receiver closed.',
      );
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
        const _NativeUploadReceiverClosedException('Native streaming upload receiver closed.'),
      );
    }
  }
}

/// Waits for both the response and the streamed request body.
///
/// A server may answer (for example 401 or 413) and close before it reads the
/// whole body. The upload then fails because its receiver closed; that is not
/// a request failure, so the response still wins. Any other upload failure
/// fails the request, and a response that arrives after the request already
/// failed is released instead of leaking its body.
Future<_NativeResponseData> _awaitResponseAndUpload(
  Future<_NativeResponseData> responseFuture,
  Future<void> uploadFuture,
) {
  final result = Completer<_NativeResponseData>();
  _NativeResponseData? response;
  var uploadDone = false;
  void settle() {
    if (result.isCompleted) return;
    if (response != null && uploadDone) result.complete(response);
  }

  responseFuture.then<void>(
    (value) {
      if (result.isCompleted) {
        _disposeResponseData(value);
        return;
      }
      response = value;
      settle();
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!result.isCompleted) result.completeError(error, stackTrace);
    },
  );
  uploadFuture.then<void>(
    (_) {
      uploadDone = true;
      settle();
    },
    onError: (Object error, StackTrace stackTrace) {
      if (error is _NativeUploadReceiverClosedException) {
        // The request body consumer is gone; the response (or the request
        // error) decides the outcome.
        uploadDone = true;
        settle();
        return;
      }
      if (result.isCompleted) return;
      result.completeError(error, stackTrace);
      final settled = response;
      if (settled != null) _disposeResponseData(settled);
    },
  );
  return result.future;
}

void _disposeResponseData(_NativeResponseData response) {
  response.body?.close();
  unawaited(response.bodyReader?.close());
  response.bodyBuffer?.close();
}

/// The native request stopped consuming a streamed request body, usually
/// because the server already answered.
final class _NativeUploadReceiverClosedException extends NativeHttpClientException {
  const _NativeUploadReceiverClosedException(super.message);
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

/// A buffered response body whose bytes become a self-owning native view.
///
/// [takeView] moves the producer context into a [NativeFinalizer] attached to
/// the returned list, so the native allocation lives exactly as long as the
/// list (and any view of it) and is reported to the GC as external memory.
final class _NativeResponseBodyLease
    implements DartHttpClientZeroCopyByteLease, TransferableNativeByteLease {
  _NativeResponseBodyLease(this._lease);

  final NativeBufferLease _lease;

  @override
  int get length => _lease.length;

  @override
  bool get isClosed => _lease.isClosed;

  @override
  Pointer<Uint8> get bytesPointer => _lease.bytesPointer;

  @override
  Uint8List get bytesView => _lease.bytesView;

  @override
  Uint8List copyBytes() => _lease.copyBytes();

  @override
  Uint8List takeDartBytes() => takeView();

  @override
  Uint8List takeView() => _lease.takeOwnedView();

  @override
  NativeBufferTransfer takeNative() => _lease.takeNative();

  @override
  void close() => _lease.close();
}

/// Turns a native byte lease into an ordinary, self-owning [Uint8List].
extension NativeHttpOwnedBufferView on TransferableNativeByteLease {
  /// Moves this lease into a [Uint8List] that owns the native allocation,
  /// without copying it.
  ///
  /// The list keeps the producer context alive through a [NativeFinalizer]
  /// and reports it to the GC as external memory, so it remains valid after
  /// the lease, the response, and the transport are closed. A producer that
  /// does not allow release from another thread is copied instead.
  Uint8List takeOwnedView() {
    final transfer = takeNative();
    final descriptor = transfer.descriptor.ref;
    final length = descriptor.len;
    if (length == 0 || descriptor.capabilities & _nexCapabilityThreadSafe == 0) {
      try {
        return length == 0 ? Uint8List(0) : Uint8List.fromList(descriptor.ptr.asTypedList(length));
      } finally {
        transfer.close();
      }
    }
    final view = descriptor.ptr.asTypedList(
      length,
      finalizer: descriptor.release.cast(),
      token: descriptor.context,
    );
    transfer.markAdopted();
    return view;
  }
}

/// `NEX_CAPABILITY_THREAD_SAFE`: the release callback may run on any thread.
const _nexCapabilityThreadSafe = 1;

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

/// Adds one response header line, combining repeated fields.
///
/// Repeated fields are joined with `, ` as RFC 9110 allows. `set-cookie` is
/// the exception: its values may contain commas (`Expires`), so they are
/// joined with `\n`, which cannot appear inside a header value.
void _addResponseHeader(Map<String, String> headers, String name, String value) {
  final existing = headers[name];
  if (existing == null) {
    headers[name] = value;
  } else {
    headers[name] = '$existing${name == 'set-cookie' ? '\n' : ', '}$value';
  }
}

String? _readCString(Pointer<Char> value) =>
    value == nullptr ? null : value.cast<Utf8>().toDartString();
