part of 'native_http_client.dart';

const _responseReaderEventReady = 7;
const _directReadChunk = 0;
const _directReadDone = 1;
const _directReadError = 2;
const _directReadCanceled = 3;

/// Demand-driven bridge from a Tokio response body to Native Exchange leases.
final class _NativeHttpResponseReader {
  _NativeHttpResponseReader._(this._transport, this._readerId, this._reader) {
    _resources = _NativeHttpResponseReaderResources(_reader);
    _nativeHttpResponseReaderFinalizer.attach(this, _resources, detach: this);
  }

  factory _NativeHttpResponseReader.adopt({
    required NativeHttpClientTransport transport,
    required int readerId,
    required Pointer<Void> reader,
  }) {
    if (readerId <= 0 || reader == nullptr) {
      throw const NativeHttpClientException('Native HTTP response reader was invalid.');
    }
    return _NativeHttpResponseReader._(transport, readerId, reader);
  }

  final NativeHttpClientTransport _transport;
  final int _readerId;
  final Pointer<Void> _reader;
  late final _NativeHttpResponseReaderResources _resources;
  Completer<void>? _pendingCompletion;
  var _nextRequestId = 1;
  var _consumed = false;
  var _terminal = false;
  var _closing = false;
  Future<void>? _closeFuture;

  Stream<NativeBufferLease> leases() async* {
    if (_consumed) throw StateError('Native HTTP response stream has already been consumed.');
    _consumed = true;
    try {
      while (!_closing) {
        final lease = await _readLease();
        if (lease == null) return;
        yield lease;
      }
    } finally {
      await close();
    }
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<NativeBufferLease?> _readLease() async {
    if (_closing || _terminal) return null;
    if (_pendingCompletion != null) {
      throw StateError('A native HTTP response read is already pending.');
    }
    final requestId = _nextRequestId++;
    final completion = Completer<void>();
    _pendingCompletion = completion;
    try {
      final status = native.dart_http_native_client_response_reader_request_next(
        _reader,
        requestId,
      );
      if (status != 0) {
        throw _responseReaderFailure('Could not request native HTTP response chunk', status);
      }
      await completion.future;
      if (_closing) return null;
      final outBuffer = calloc<NexBuffer>();
      final readStatus = native.dart_http_native_client_response_reader_take(
        _reader,
        requestId,
        outBuffer.cast(),
      );
      switch (readStatus) {
        case _directReadChunk:
          return NativeBufferLease.fromPointer(outBuffer);
        case _directReadDone || _directReadCanceled:
          _terminal = true;
          calloc.free(outBuffer);
          return null;
        case _directReadError:
          _terminal = true;
          final diagnostic = NativeBufferLease.fromPointer(outBuffer);
          try {
            throw NativeHttpClientException(
              utf8.decode(diagnostic.bytesView, allowMalformed: true),
            );
          } finally {
            diagnostic.close();
          }
        default:
          calloc.free(outBuffer);
          throw _responseReaderFailure('Could not take native HTTP response chunk', readStatus);
      }
    } finally {
      _pendingCompletion = null;
    }
  }

  void _handleNotification() {
    final completion = _pendingCompletion;
    if (completion != null && !completion.isCompleted) completion.complete();
  }

  void _transportClosed() {
    _closing = true;
    final completion = _pendingCompletion;
    if (completion != null && !completion.isCompleted) completion.complete();
    _nativeHttpResponseReaderFinalizer.detach(this);
    _resources.release();
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    native.dart_http_native_client_response_reader_cancel(_reader);
    await _pendingCompletion?.future;
    _transport._responseReaders.remove(_readerId);
    _nativeHttpResponseReaderFinalizer.detach(this);
    _resources.release();
  }
}

final class _NativeHttpResponseReaderResources {
  _NativeHttpResponseReaderResources(this.reader);

  final Pointer<Void> reader;
  var _released = false;

  void release() {
    if (_released) return;
    _released = true;
    native.dart_http_native_client_response_reader_release(reader);
  }
}

final _nativeHttpResponseReaderFinalizer = Finalizer<_NativeHttpResponseReaderResources>(
  (resources) => resources.release(),
);

NativeHttpClientException _responseReaderFailure(String message, int code) {
  final detail = switch (code) {
    -1 => 'invalid argument',
    -4 => 'another read is pending',
    -5 => 'Tokio response task stopped',
    -6 => 'response chunk is unavailable',
    _ => 'unknown status',
  };
  return NativeHttpClientException('$message: $detail ($code).');
}
