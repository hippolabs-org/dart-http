import 'dart:ffi';
import 'dart:typed_data';

import 'package:dart_http_core/dart_http_core.dart';
import 'package:native_exchange/native_exchange_ffi.dart';

/// Single-owner view over a contiguous payload retained by native code.
///
/// [bytesPointer] and [bytesView] remain valid only until [close]. Native consumers
/// can synchronously borrow the pointer without allocating Dart-managed input.
final class RuntimeNativeBinaryPayloadLease implements BinaryPayloadLease, NativeByteLease {
  RuntimeNativeBinaryPayloadLease.fromPointer({
    required Pointer<Uint8> bytesPtr,
    required int length,
    required this._release,
  }) : _bytesPtr = bytesPtr,
       _length = RangeError.checkNotNegative(length, 'length') {
    if (length > 0 && bytesPtr == nullptr) {
      throw ArgumentError.value(
        bytesPtr,
        'bytesPtr',
        'Pointer must not be null for a non-empty payload.',
      );
    }
  }

  Pointer<Uint8> _bytesPtr;
  final int _length;
  final void Function() _release;
  var _isClosed = false;
  final _closeListeners = <void Function()>[];

  /// Registers bounded lifetime bookkeeping without scanning other leases.
  void onClose(void Function() listener) {
    if (_isClosed) {
      listener();
    } else {
      _closeListeners.add(listener);
    }
  }

  /// Borrowed pointer to the payload.
  ///
  /// The pointer becomes invalid when this lease is closed.
  @override
  Pointer<Uint8> get bytesPointer {
    _ensureOpen();
    return _bytesPtr;
  }

  @override
  int get length {
    _ensureOpen();
    return _length;
  }

  @override
  bool get isClosed => _isClosed;

  @override
  Uint8List get bytesView {
    _ensureOpen();
    if (_length == 0) return Uint8List(0);
    return _bytesPtr.asTypedList(_length);
  }

  @override
  Uint8List copyBytes() => Uint8List.fromList(bytesView);

  @override
  Uint8List takeBytes() {
    try {
      return copyBytes();
    } finally {
      close();
    }
  }

  @override
  Uint8List takeDartBytes() => takeBytes();

  @override
  void close() {
    if (_isClosed) return;
    _isClosed = true;
    _bytesPtr = nullptr;
    try {
      _release();
    } finally {
      for (final listener in _closeListeners) {
        listener();
      }
      _closeListeners.clear();
    }
  }

  void _ensureOpen() {
    if (isClosed) {
      throw StateError('Native binary payload lease is closed.');
    }
  }
}
