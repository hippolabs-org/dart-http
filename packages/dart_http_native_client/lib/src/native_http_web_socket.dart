part of 'native_http_client.dart';

const _webSocketEventOpened = 1;
const _webSocketEventText = 2;
const _webSocketEventBinary = 3;
const _webSocketEventClosed = 4;
const _webSocketEventError = 5;
const _webSocketEventSent = 6;

extension on NativeHttpClientTransport {
  Future<NativeHttpWebSocket> _connectWebSocket(DartHttpClientWebSocketRequest request) async {
    _ensureOpen();
    if (request.uri.scheme != 'ws' && request.uri.scheme != 'wss') {
      throw ArgumentError.value(
        request.uri,
        'request.uri',
        'Native WebSocket URLs must use ws or wss.',
      );
    }
    final url = request.uri.toString().toNativeUtf8();
    final headers = request.headers.isEmpty
        ? nullptr.cast<native.NativeHttpHeader>()
        : calloc<native.NativeHttpHeader>(request.headers.length);
    final headerStrings = <Pointer<Utf8>>[];
    final protocols = request.protocols.isEmpty
        ? nullptr.cast<Pointer<Char>>()
        : calloc<Pointer<Char>>(request.protocols.length);
    final protocolStrings = <Pointer<Utf8>>[];
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
      for (var index = 0; index < request.protocols.length; index++) {
        final protocol = request.protocols[index].toNativeUtf8();
        protocolStrings.add(protocol);
        protocols[index] = protocol.cast();
      }
      final socketId = native.dart_http_native_client_websocket_connect(
        _clientId,
        url.cast(),
        headers,
        request.headers.length,
        protocols,
        request.protocols.length,
        _webSocketIncomingCapacity,
        _webSocketOutgoingCapacity,
      );
      if (socketId <= 0) {
        throw const NativeHttpClientException('The native WebSocket connection was rejected.');
      }
      final socket = NativeHttpWebSocket._(this, socketId);
      _webSockets[socketId] = socket;
      try {
        await socket._connected.future;
        return socket;
      } catch (_) {
        socket._abortNative();
        rethrow;
      }
    } finally {
      calloc.free(url);
      if (headers != nullptr) calloc.free(headers);
      for (final value in headerStrings) {
        calloc.free(value);
      }
      if (protocols != nullptr) calloc.free(protocols);
      for (final value in protocolStrings) {
        calloc.free(value);
      }
    }
  }
}

/// Active WebSocket driven by Tokio/tungstenite with leased binary frames.
final class NativeHttpWebSocket implements DartHttpClientWebSocket {
  NativeHttpWebSocket._(this._transport, this._socketId) {
    _controller = StreamController<WebSocketMessage>(
      sync: true,
      onListen: _onListen,
      onPause: _onPause,
      onResume: _onResume,
      onCancel: _onCancel,
    );
  }

  final NativeHttpClientTransport _transport;
  final int _socketId;
  final Completer<void> _connected = Completer<void>();
  final Map<int, Completer<void>> _pendingOperations = {};
  final List<int> _deferredDataNotifications = [];
  late final StreamController<WebSocketMessage> _controller;
  String? _selectedProtocol;
  var _listening = false;
  var _paused = false;
  var _flushing = false;
  var _discardData = false;
  var _terminal = false;
  var _closing = false;
  var _queuedOperations = 0;

  /// Subprotocol selected by the server, when one was negotiated.
  String? get selectedProtocol => _selectedProtocol;

  @override
  Stream<WebSocketMessage> get messages => _controller.stream;

  @override
  Future<void> sendText(String value) => _scheduleOperation(() {
    final text = value.toNativeUtf8();
    try {
      return native.dart_http_native_client_websocket_send_text(
        _transport._clientId,
        _socketId,
        text.cast(),
      );
    } finally {
      calloc.free(text);
    }
  });

  @override
  Future<void> sendJson(Object? value) => sendText(jsonEncode(value));

  @override
  Future<void> sendBinary(List<int> value) => _scheduleOperation(() {
    final bytes = value is Uint8List ? value : Uint8List.fromList(value);
    final pointer = bytes.isEmpty ? nullptr.cast<Uint8>() : calloc<Uint8>(bytes.length);
    try {
      if (bytes.isNotEmpty) pointer.asTypedList(bytes.length).setAll(0, bytes);
      return native.dart_http_native_client_websocket_send_binary(
        _transport._clientId,
        _socketId,
        pointer,
        bytes.length,
      );
    } finally {
      if (pointer != nullptr) calloc.free(pointer);
    }
  });

  @override
  Future<void> close([int? code, String? reason]) async {
    if (_terminal || _closing) return;
    _closing = true;
    _discardData = true;
    _flushDeferredData();
    await _scheduleOperation(() {
      final nativeReason = reason?.toNativeUtf8();
      try {
        return native.dart_http_native_client_websocket_close(
          _transport._clientId,
          _socketId,
          code ?? -1,
          nativeReason?.cast() ?? nullptr,
        );
      } finally {
        if (nativeReason != null) calloc.free(nativeReason);
      }
    }, allowClosing: true);
  }

  Future<void> _scheduleOperation(int Function() start, {bool allowClosing = false}) {
    if (_terminal || (!_connected.isCompleted)) {
      return Future<void>.error(
        const NativeHttpClientException('Native WebSocket is not connected.'),
      );
    }
    if (_closing && !allowClosing) {
      return Future<void>.error(const NativeHttpClientException('Native WebSocket is closing.'));
    }
    if (_queuedOperations >= _transport._webSocketOutgoingCapacity) {
      return Future<void>.error(
        const NativeHttpClientException('Native WebSocket send queue is full.'),
      );
    }
    _queuedOperations++;
    final previous = _operationTail;
    final operation = previous.then((_) async {
      if (_terminal) {
        throw const NativeHttpClientException('Native WebSocket is closed.');
      }
      final operationId = start();
      if (operationId <= 0) {
        throw const NativeHttpClientException('Native WebSocket send queue is full.');
      }
      final completer = Completer<void>();
      _pendingOperations[operationId] = completer;
      await completer.future;
    });
    _operationTail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation.whenComplete(() => _queuedOperations--);
  }

  Future<void> _operationTail = Future<void>.value();

  void _handleNotification(int kind) {
    if (_terminal) {
      _discardNativeEvent(kind);
      return;
    }
    if (kind == _webSocketEventText || kind == _webSocketEventBinary) {
      if (!_discardData && (!_listening || _paused)) {
        _deferredDataNotifications.add(kind);
        return;
      }
    }
    _takeNativeEvent(kind);
  }

  void _takeNativeEvent(int kind) {
    final event = native.dart_http_native_client_websocket_take_event(
      _transport._clientId,
      _socketId,
      kind,
    );
    if (event == nullptr) return;
    try {
      final value = event.ref;
      final text = _readCString(value.text);
      switch (value.kind) {
        case _webSocketEventOpened:
          _selectedProtocol = text;
          if (!_connected.isCompleted) _connected.complete();
        case _webSocketEventText:
          if (!_discardData) {
            _controller.add(WebSocketMessage.text(text ?? ''));
          }
        case _webSocketEventBinary:
          final descriptor = calloc<NexBuffer>();
          final transferred = native.dart_http_native_client_websocket_event_take_binary(
            event,
            descriptor.cast(),
          );
          if (!transferred) {
            calloc.free(descriptor);
            throw const NativeHttpClientException('Native WebSocket binary event had no buffer.');
          }
          final lease = NativeBufferLease.fromPointer(descriptor);
          final message = WebSocketMessage.leasedBinary(BinaryPayloadLease.fromByteLease(lease));
          if (_discardData) {
            message.close();
          } else {
            _controller.add(message);
          }
        case _webSocketEventClosed:
          _finish();
        case _webSocketEventError:
          final error = NativeHttpClientException(text ?? 'Native WebSocket failed.');
          if (!_connected.isCompleted) _connected.completeError(error);
          if (!_controller.isClosed) _controller.addError(error);
          _finish(error);
        case _webSocketEventSent:
          _pendingOperations.remove(value.operation_id)?.complete();
        default:
          throw NativeHttpClientException('Unknown native WebSocket event kind ${value.kind}.');
      }
    } catch (error, stackTrace) {
      if (!_connected.isCompleted) _connected.completeError(error, stackTrace);
      if (!_controller.isClosed) _controller.addError(error, stackTrace);
      _finish(error, stackTrace);
    } finally {
      native.dart_http_native_client_websocket_free_event(event);
    }
  }

  void _discardNativeEvent(int kind) {
    final event = native.dart_http_native_client_websocket_take_event(
      _transport._clientId,
      _socketId,
      kind,
    );
    if (event != nullptr) native.dart_http_native_client_websocket_free_event(event);
  }

  void _onListen() {
    _listening = true;
    _flushDeferredData();
  }

  void _onPause() => _paused = true;

  void _onResume() {
    _paused = false;
    _flushDeferredData();
  }

  Future<void> _onCancel() async {
    _discardData = true;
    _abortNative();
    _finish();
  }

  void _flushDeferredData() {
    if (_flushing || _terminal || (!_discardData && (!_listening || _paused))) return;
    _flushing = true;
    scheduleMicrotask(() {
      try {
        while (_deferredDataNotifications.isNotEmpty &&
            !_terminal &&
            (_discardData || (_listening && !_paused))) {
          _takeNativeEvent(_deferredDataNotifications.removeAt(0));
        }
      } finally {
        _flushing = false;
        if (_deferredDataNotifications.isNotEmpty &&
            !_terminal &&
            (_discardData || (_listening && !_paused))) {
          _flushDeferredData();
        }
      }
    });
  }

  void _transportClosed() {
    final error = const NativeHttpClientException('Native HTTP client closed.');
    if (!_connected.isCompleted) _connected.completeError(error);
    if (!_controller.isClosed) _controller.addError(error);
    _finish(error);
  }

  void _finish([Object? error, StackTrace? stackTrace]) {
    if (_terminal) return;
    _terminal = true;
    _abortNative();
    final failure = error ?? const NativeHttpClientException('Native WebSocket closed.');
    for (final completer in _pendingOperations.values) {
      if (!completer.isCompleted) completer.completeError(failure, stackTrace);
    }
    _pendingOperations.clear();
    if (!_connected.isCompleted && error == null) _connected.complete();
    if (!_controller.isClosed) unawaited(_controller.close());
  }

  void _abortNative() {
    _transport._webSockets.remove(_socketId);
    native.dart_http_native_client_websocket_abort(_transport._clientId, _socketId);
  }
}
