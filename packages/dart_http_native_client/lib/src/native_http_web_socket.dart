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
final class NativeHttpWebSocket
    implements
        DartHttpClientNativeStreamWebSocket,
        DartHttpClientBase64TextWebSocket,
        DartHttpClientCloseAwareWebSocket {
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
  final List<int> _deferredStreamNotifications = [];
  late final StreamController<WebSocketMessage> _controller;
  String? _selectedProtocol;
  DartHttpClientWebSocketCloseDetails? _closeDetails;
  var _listening = false;
  var _paused = false;
  var _flushing = false;
  var _discardData = false;
  var _terminal = false;
  var _closing = false;
  var _queuedOperations = 0;
  _NativeHttpWebSocketAdoptedStream? _byteStream;

  /// Subprotocol selected by the server, when one was negotiated.
  String? get selectedProtocol => _selectedProtocol;

  @override
  DartHttpClientWebSocketCloseDetails? get closeDetails => _closeDetails;

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
  Future<void> sendTextBase64Lease(
    BinaryPayloadLease lease, {
    String prefix = '',
    String suffix = '',
    int offset = 0,
    int? length,
  }) {
    final selectedLength = length ?? lease.length - offset;
    try {
      RangeError.checkValidRange(offset, offset + selectedLength, lease.length, 'offset');
    } catch (_) {
      lease.close();
      rethrow;
    }
    final exchangeLease = switch (lease) {
      NativeExchangeBinaryPayloadLease(lease: final byteLease) => byteLease,
      _ => null,
    };
    if (exchangeLease is! TransferableNativeByteLease) {
      try {
        final bytes = Uint8List.sublistView(lease.bytesView, offset, offset + selectedLength);
        return sendText('$prefix${base64Encode(bytes)}$suffix').whenComplete(lease.close);
      } catch (_) {
        lease.close();
        rethrow;
      }
    }
    return _scheduleOperation(() {
      final prefixPointer = prefix.toNativeUtf8();
      final suffixPointer = suffix.toNativeUtf8();
      final transfer = exchangeLease.takeNative();
      try {
        final result = native.dart_http_native_client_websocket_send_text_base64_native(
          _transport._clientId,
          _socketId,
          prefixPointer.cast(),
          prefixPointer.length,
          transfer.descriptor.cast(),
          offset,
          selectedLength,
          suffixPointer.cast(),
          suffixPointer.length,
        );
        if (result != 0) {
          transfer.markAdopted();
        } else {
          transfer.close();
        }
        return result > 0 ? result : 0;
      } catch (_) {
        transfer.close();
        rethrow;
      } finally {
        calloc
          ..free(prefixPointer)
          ..free(suffixPointer);
      }
    }).whenComplete(() {
      if (!lease.isClosed) lease.close();
    });
  }

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
  Future<void> sendBinaryLease(BinaryPayloadLease lease, {List<int> prefix = const <int>[]}) {
    final exchangeLease = switch (lease) {
      NativeExchangeBinaryPayloadLease(lease: final byteLease) => byteLease,
      _ => null,
    };
    if (exchangeLease is! TransferableNativeByteLease) {
      if (prefix.isEmpty) {
        return sendBinary(lease.takeBytes());
      }
      try {
        final combined = Uint8List(prefix.length + lease.length)
          ..setRange(0, prefix.length, prefix)
          ..setRange(prefix.length, prefix.length + lease.length, lease.bytesView);
        return sendBinary(combined);
      } finally {
        lease.close();
      }
    }
    return _scheduleOperation(() {
      final prefixPointer = prefix.isEmpty ? nullptr.cast<Uint8>() : calloc<Uint8>(prefix.length);
      final transfer = exchangeLease.takeNative();
      try {
        if (prefix.isNotEmpty) {
          prefixPointer.asTypedList(prefix.length).setAll(0, prefix);
        }
        final result = native.dart_http_native_client_websocket_send_binary_native_prefixed(
          _transport._clientId,
          _socketId,
          prefixPointer,
          prefix.length,
          transfer.descriptor.cast(),
        );
        if (result != 0) {
          transfer.markAdopted();
        } else {
          transfer.close();
        }
        return result > 0 ? result : 0;
      } catch (_) {
        transfer.close();
        rethrow;
      } finally {
        if (prefixPointer != nullptr) calloc.free(prefixPointer);
      }
    }).whenComplete(() {
      if (!lease.isClosed) lease.close();
    });
  }

  @override
  void enqueueByteLease(ByteLease lease, {List<int> prefix = const <int>[]}) {
    if (_terminal || !_connected.isCompleted) {
      lease.close();
      throw const NativeHttpClientException('Native WebSocket is not connected.');
    }
    if (_closing) {
      lease.close();
      throw const NativeHttpClientException('Native WebSocket is closing.');
    }
    if (lease is! TransferableNativeByteLease) {
      lease.close();
      throw UnsupportedError(
        'Queued zero-copy WebSocket sends require a transferable native byte lease.',
      );
    }
    final prefixPointer = prefix.isEmpty ? nullptr.cast<Uint8>() : calloc<Uint8>(prefix.length);
    final transfer = lease.takeNative();
    try {
      if (prefix.isNotEmpty) {
        prefixPointer.asTypedList(prefix.length).setAll(0, prefix);
      }
      final result = native.dart_http_native_client_websocket_enqueue_binary_native_prefixed(
        _transport._clientId,
        _socketId,
        prefixPointer,
        prefix.length,
        transfer.descriptor.cast(),
      );
      if (result == 1 || result == -2) {
        transfer.markAdopted();
      } else {
        transfer.close();
      }
      if (result == 1) return;
      if (result == -1) {
        throw const NativeHttpClientException('Native WebSocket send queue is full.');
      }
      if (result == -2) {
        throw const NativeHttpClientException('Native WebSocket closed while accepting a send.');
      }
      throw const NativeHttpClientException('Native WebSocket rejected the native byte lease.');
    } catch (_) {
      transfer.close();
      rethrow;
    } finally {
      if (prefixPointer != nullptr) calloc.free(prefixPointer);
    }
  }

  @override
  void enqueueBinaryLease(BinaryPayloadLease lease, {List<int> prefix = const <int>[]}) {
    final byteLease = switch (lease) {
      NativeExchangeBinaryPayloadLease(lease: final value) => value,
      _ => null,
    };
    if (byteLease == null) {
      lease.close();
      throw UnsupportedError(
        'Queued zero-copy WebSocket sends require a Native Exchange payload lease.',
      );
    }
    try {
      enqueueByteLease(byteLease, prefix: prefix);
    } finally {
      if (!lease.isClosed) lease.close();
    }
  }

  @override
  void enqueueTextBase64Lease(
    BinaryPayloadLease lease, {
    String prefix = '',
    String suffix = '',
    int offset = 0,
    int? length,
  }) {
    final selectedLength = length ?? lease.length - offset;
    try {
      RangeError.checkValidRange(offset, offset + selectedLength, lease.length, 'offset');
    } catch (_) {
      lease.close();
      rethrow;
    }
    final byteLease = switch (lease) {
      NativeExchangeBinaryPayloadLease(lease: final value) => value,
      _ => null,
    };
    if (byteLease is! TransferableNativeByteLease) {
      lease.close();
      throw UnsupportedError(
        'Queued base64 WebSocket sends require a Native Exchange payload lease.',
      );
    }
    if (_terminal || !_connected.isCompleted || _closing) {
      lease.close();
      throw const NativeHttpClientException('Native WebSocket cannot accept a queued send.');
    }
    final prefixPointer = prefix.toNativeUtf8();
    final suffixPointer = suffix.toNativeUtf8();
    final transfer = byteLease.takeNative();
    try {
      final result = native.dart_http_native_client_websocket_enqueue_text_base64_native(
        _transport._clientId,
        _socketId,
        prefixPointer.cast(),
        prefixPointer.length,
        transfer.descriptor.cast(),
        offset,
        selectedLength,
        suffixPointer.cast(),
        suffixPointer.length,
      );
      if (result == 1 || result == -2) {
        transfer.markAdopted();
      } else {
        transfer.close();
      }
      if (result == 1) return;
      if (result == -1) {
        throw const NativeHttpClientException('Native WebSocket send queue is full.');
      }
      if (result == -2) {
        throw const NativeHttpClientException('Native WebSocket closed while accepting a send.');
      }
      throw const NativeHttpClientException('Native WebSocket rejected the base64 payload lease.');
    } catch (_) {
      transfer.close();
      rethrow;
    } finally {
      if (!lease.isClosed) lease.close();
      calloc
        ..free(prefixPointer)
        ..free(suffixPointer);
    }
  }

  @override
  Future<void> flush() => _scheduleOperation(
    () => native.dart_http_native_client_websocket_flush(_transport._clientId, _socketId),
  );

  @override
  DartHttpClientNativeWebSocketByteStream adoptByteStream(ByteStreamLease stream) {
    _adoptByteStream(stream);
    return _byteStream = _NativeHttpWebSocketByteStream(this);
  }

  @override
  DartHttpClientNativeWebSocketBase64TextStream adoptBase64TextStream(ByteStreamLease stream) {
    _adoptByteStream(stream);
    return _byteStream = _NativeHttpWebSocketBase64TextStream(this);
  }

  void _adoptByteStream(ByteStreamLease stream) {
    if (_terminal || !_connected.isCompleted || _closing) {
      unawaited(Future<void>.sync(stream.close));
      throw const NativeHttpClientException('Native WebSocket cannot adopt a byte stream.');
    }
    if (_byteStream != null) {
      unawaited(Future<void>.sync(stream.close));
      throw StateError('This Native WebSocket already has an adopted byte stream.');
    }
    if (stream is! NativeByteStreamHandle) {
      unawaited(Future<void>.sync(stream.close));
      throw UnsupportedError(
        'The native HTTP client requires a Native Exchange byte-stream handle.',
      );
    }
    final transfer = stream.takeNative();
    try {
      final result = native.dart_http_native_client_websocket_adopt_byte_stream(
        _transport._clientId,
        _socketId,
        transfer.descriptor.cast(),
      );
      if (result == 1) {
        transfer.markAdopted();
        return;
      }
      transfer.close();
      if (result == -1) {
        throw StateError('This Native WebSocket already has an adopted byte stream.');
      }
      throw const NativeHttpClientException('Native WebSocket rejected the byte stream.');
    } catch (_) {
      transfer.close();
      rethrow;
    }
  }

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
        _deferredStreamNotifications.add(kind);
        return;
      }
    }
    if ((kind == _webSocketEventClosed || kind == _webSocketEventError) &&
        !_discardData &&
        _deferredStreamNotifications.isNotEmpty) {
      _deferredStreamNotifications.add(kind);
      return;
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
          _closeDetails = DartHttpClientWebSocketCloseDetails(
            code: value.close_code < 0 ? null : value.close_code,
            reason: text,
          );
          _finish();
        case _webSocketEventError:
          final error = NativeHttpClientException(text ?? 'Native WebSocket failed.');
          final failedWhileConnecting = !_connected.isCompleted;
          if (failedWhileConnecting) {
            _connected.completeError(error);
          } else if (!_controller.isClosed) {
            _controller.addError(error);
          }
          _finish(error);
        case _webSocketEventSent:
          _pendingOperations.remove(value.operation_id)?.complete();
        default:
          throw NativeHttpClientException('Unknown native WebSocket event kind ${value.kind}.');
      }
    } catch (error, stackTrace) {
      final failedWhileConnecting = !_connected.isCompleted;
      if (failedWhileConnecting) {
        _connected.completeError(error, stackTrace);
      } else if (!_controller.isClosed) {
        _controller.addError(error, stackTrace);
      }
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
        while (_deferredStreamNotifications.isNotEmpty &&
            !_terminal &&
            (_discardData || (_listening && !_paused))) {
          _takeNativeEvent(_deferredStreamNotifications.removeAt(0));
        }
      } finally {
        _flushing = false;
        if (_deferredStreamNotifications.isNotEmpty &&
            !_terminal &&
            (_discardData || (_listening && !_paused))) {
          _flushDeferredData();
        }
      }
    });
  }

  void _transportClosed() {
    final error = const NativeHttpClientException('Native HTTP client closed.');
    final failedWhileConnecting = !_connected.isCompleted;
    if (failedWhileConnecting) {
      _connected.completeError(error);
    } else if (!_controller.isClosed) {
      _controller.addError(error);
    }
    _finish(error);
  }

  void _finish([Object? error, StackTrace? stackTrace]) {
    if (_terminal) return;
    _terminal = true;
    _byteStream?._socketClosed();
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

abstract base class _NativeHttpWebSocketAdoptedStream {
  _NativeHttpWebSocketAdoptedStream(this._socket);

  final NativeHttpWebSocket _socket;
  bool _closed = false;

  Future<DartHttpClientNativeWebSocketByteStreamStats> pauseAndFlush() async {
    _ensureOpen();
    await _socket._scheduleOperation(
      () => native.dart_http_native_client_websocket_pause_byte_stream(
        _socket._transport._clientId,
        _socket._socketId,
      ),
    );
    final chunkCount = calloc<Uint64>();
    final byteCount = calloc<Uint64>();
    try {
      final read = native.dart_http_native_client_websocket_byte_stream_stats(
        _socket._transport._clientId,
        _socket._socketId,
        chunkCount,
        byteCount,
      );
      if (!read) {
        throw const NativeHttpClientException('Native WebSocket stream counters are unavailable.');
      }
      return DartHttpClientNativeWebSocketByteStreamStats(
        chunkCount: chunkCount.value,
        byteCount: byteCount.value,
      );
    } finally {
      calloc.free(chunkCount);
      calloc.free(byteCount);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    native.dart_http_native_client_websocket_close_byte_stream(
      _socket._transport._clientId,
      _socket._socketId,
    );
    _socket._byteStream = null;
  }

  void _socketClosed() => _closed = true;

  void _ensureOpen() {
    if (_closed || _socket._terminal || _socket._closing) {
      throw StateError('Native WebSocket byte stream is closed.');
    }
  }
}

final class _NativeHttpWebSocketByteStream extends _NativeHttpWebSocketAdoptedStream
    implements DartHttpClientNativeWebSocketByteStream {
  _NativeHttpWebSocketByteStream(super.socket);

  @override
  void resume({
    List<int> prefix = const <int>[],
    int sequenceOffset = -1,
    int payloadUnitCountOffset = -1,
    int bytesPerPayloadUnit = 1,
  }) {
    _ensureOpen();
    if (bytesPerPayloadUnit <= 0) {
      throw ArgumentError.value(bytesPerPayloadUnit, 'bytesPerPayloadUnit', 'Must be positive.');
    }
    final prefixPointer = prefix.isEmpty ? nullptr.cast<Uint8>() : calloc<Uint8>(prefix.length);
    try {
      if (prefix.isNotEmpty) prefixPointer.asTypedList(prefix.length).setAll(0, prefix);
      final accepted = native.dart_http_native_client_websocket_resume_byte_stream(
        _socket._transport._clientId,
        _socket._socketId,
        prefixPointer,
        prefix.length,
        sequenceOffset,
        payloadUnitCountOffset,
        bytesPerPayloadUnit,
      );
      if (!accepted) {
        throw const NativeHttpClientException('Native WebSocket rejected the stream framing.');
      }
    } finally {
      if (prefixPointer != nullptr) calloc.free(prefixPointer);
    }
  }
}

final class _NativeHttpWebSocketBase64TextStream extends _NativeHttpWebSocketAdoptedStream
    implements DartHttpClientNativeWebSocketBase64TextStream {
  _NativeHttpWebSocketBase64TextStream(super.socket);

  @override
  void resume({String prefix = '', String suffix = ''}) {
    _ensureOpen();
    final prefixPointer = prefix.toNativeUtf8();
    final suffixPointer = suffix.toNativeUtf8();
    try {
      final accepted = native.dart_http_native_client_websocket_resume_base64_text_stream(
        _socket._transport._clientId,
        _socket._socketId,
        prefixPointer.cast(),
        prefixPointer.length,
        suffixPointer.cast(),
        suffixPointer.length,
      );
      if (!accepted) {
        throw const NativeHttpClientException('Native WebSocket rejected the base64 framing.');
      }
    } finally {
      calloc
        ..free(prefixPointer)
        ..free(suffixPointer);
    }
  }
}
