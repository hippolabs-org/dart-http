import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'generated_bindings.dart' as gen;

const _nativeByteStreamAbiVersion = 1;
const _nativeByteStreamReadChunk = 0;
const _nativeByteStreamReadDone = 1;
const _nativeByteStreamReadError = 2;
const _nativeByteStreamReadCanceled = 3;

typedef NativeByteStreamDescriptor = gen.NativeByteStream;

enum _NativeByteStreamState { available, reading, transferred, closed }

/// A single-owner handle for a byte stream produced by a native asset.
///
/// A handle may either be consumed as Dart chunks through [openRead] or moved
/// into another native component through [takeDescriptor]. The two modes are
/// intentionally mutually exclusive.
final class NativeByteStreamHandle {
  NativeByteStreamHandle.fromDescriptor(gen.NativeByteStream descriptor)
    : _descriptor = _validatedCopyDescriptor(descriptor) {
    _descriptorFinalizer.attach(this, _descriptor.address, detach: this);
  }

  /// Reconstructs a descriptor returned from work performed in another Dart
  /// isolate. Only addresses are transferred; the body bytes stay native.
  NativeByteStreamHandle.fromAddresses(NativeByteStreamDescriptorData descriptor)
    : _descriptor = _descriptorPointerFromAddresses(descriptor) {
    _validateDescriptor(_descriptor.ref);
    _descriptorFinalizer.attach(this, _descriptor.address, detach: this);
  }

  final Pointer<gen.NativeByteStream> _descriptor;
  _NativeByteStreamState _state = _NativeByteStreamState.available;
  Future<_NativeByteStreamReadResult>? _activeRead;
  Future<void>? _closeFuture;

  /// Reads the native body as copied Dart-owned chunks.
  ///
  /// Listening more than once, or listening after native ownership was taken,
  /// throws a [StateError].
  Stream<Uint8List> openRead() async* {
    if (_state != _NativeByteStreamState.available) {
      throw StateError('Native byte stream has already been consumed.');
    }
    _state = _NativeByteStreamState.reading;
    try {
      while (_state == _NativeByteStreamState.reading) {
        final read = _activeRead = Isolate.run(() => _readDescriptor(_descriptor.address));
        final result = await read;
        _activeRead = null;
        switch (result.status) {
          case _nativeByteStreamReadChunk:
            if (result.bytes.isNotEmpty) {
              yield result.bytes;
            }
          case _nativeByteStreamReadDone:
            return;
          case _nativeByteStreamReadCanceled:
            return;
          case _nativeByteStreamReadError:
            throw StateError(result.error ?? 'Native byte stream read failed.');
          default:
            throw StateError('Native byte stream returned unknown status ${result.status}.');
        }
      }
    } finally {
      _activeRead = null;
      await close();
    }
  }

  /// Moves this stream descriptor into a native consumer.
  NativeByteStreamLease takeDescriptor() {
    if (_state != _NativeByteStreamState.available) {
      throw StateError('Native byte stream has already been consumed.');
    }
    _state = _NativeByteStreamState.transferred;
    _descriptorFinalizer.detach(this);
    return NativeByteStreamLease._(_descriptor);
  }

  /// Cancels and releases this stream. The operation is idempotent.
  Future<void> close() {
    return _closeFuture ??= _close();
  }

  Future<void> _close() async {
    if (_state == _NativeByteStreamState.transferred || _state == _NativeByteStreamState.closed) {
      return;
    }
    _state = _NativeByteStreamState.closed;
    _cancelDescriptor(_descriptor.address);
    await _activeRead;
    _descriptorFinalizer.detach(this);
    _releaseDescriptor(_descriptor.address, cancel: false);
  }
}

/// Sendable address representation of a native byte-stream descriptor.
final class NativeByteStreamDescriptorData {
  const NativeByteStreamDescriptorData({
    required this.abiVersion,
    required this.structSize,
    required this.contextAddress,
    required this.nextAddress,
    required this.cancelAddress,
    required this.freeReadAddress,
    required this.releaseAddress,
  });

  factory NativeByteStreamDescriptorData.fromDescriptor(gen.NativeByteStream descriptor) {
    _validateDescriptor(descriptor);
    return NativeByteStreamDescriptorData(
      abiVersion: descriptor.abi_version,
      structSize: descriptor.struct_size,
      contextAddress: descriptor.context.address,
      nextAddress: descriptor.next.address,
      cancelAddress: descriptor.cancel.address,
      freeReadAddress: descriptor.free_read.address,
      releaseAddress: descriptor.release.address,
    );
  }

  final int abiVersion;
  final int structSize;
  final int contextAddress;
  final int nextAddress;
  final int cancelAddress;
  final int freeReadAddress;
  final int releaseAddress;
}

/// Temporary ownership of a native stream descriptor during an FFI transfer.
final class NativeByteStreamLease {
  NativeByteStreamLease._(this.descriptor) {
    _descriptorFinalizer.attach(this, descriptor.address, detach: this);
  }

  /// Descriptor passed to the adopting native function.
  final Pointer<gen.NativeByteStream> descriptor;
  var _settled = false;

  /// Marks the descriptor as adopted by the native consumer.
  ///
  /// This releases only the Dart descriptor storage. The adopted native
  /// consumer now owns the producer context and its release callback.
  void markTransferred() {
    if (_settled) {
      return;
    }
    _settled = true;
    _descriptorFinalizer.detach(this);
    calloc.free(descriptor);
  }

  /// Cancels and releases the descriptor when native adoption failed.
  void close() {
    if (_settled) {
      return;
    }
    _settled = true;
    _descriptorFinalizer.detach(this);
    _releaseDescriptor(descriptor.address, cancel: true);
  }
}

final _descriptorFinalizer = Finalizer<int>((address) => _releaseDescriptor(address, cancel: true));

Pointer<gen.NativeByteStream> _validatedCopyDescriptor(gen.NativeByteStream descriptor) {
  _validateDescriptor(descriptor);
  final copy = calloc<gen.NativeByteStream>();
  copy.ref
    ..abi_version = descriptor.abi_version
    ..struct_size = descriptor.struct_size
    ..context = descriptor.context
    ..next = descriptor.next
    ..cancel = descriptor.cancel
    ..free_read = descriptor.free_read
    ..release = descriptor.release;
  return copy;
}

Pointer<gen.NativeByteStream> _descriptorPointerFromAddresses(
  NativeByteStreamDescriptorData descriptor,
) {
  final pointer = calloc<gen.NativeByteStream>();
  pointer.ref
    ..abi_version = descriptor.abiVersion
    ..struct_size = descriptor.structSize
    ..context = Pointer<Void>.fromAddress(descriptor.contextAddress)
    ..next = Pointer.fromAddress(descriptor.nextAddress)
    ..cancel = Pointer.fromAddress(descriptor.cancelAddress)
    ..free_read = Pointer.fromAddress(descriptor.freeReadAddress)
    ..release = Pointer.fromAddress(descriptor.releaseAddress);
  return pointer;
}

void _validateDescriptor(gen.NativeByteStream descriptor) {
  if (descriptor.abi_version != _nativeByteStreamAbiVersion ||
      descriptor.struct_size < sizeOf<gen.NativeByteStream>() ||
      descriptor.context == nullptr ||
      descriptor.next == nullptr ||
      descriptor.free_read == nullptr ||
      descriptor.release == nullptr) {
    throw ArgumentError('Invalid native byte-stream descriptor.');
  }
}

typedef _NextDart = Pointer<gen.NativeByteStreamRead> Function(Pointer<Void> context);
typedef _CancelDart = void Function(Pointer<Void> context);
typedef _FreeReadDart = void Function(Pointer<gen.NativeByteStreamRead> value);
typedef _ReleaseDart = void Function(Pointer<Void> context);

_NativeByteStreamReadResult _readDescriptor(int address) {
  final descriptor = Pointer<gen.NativeByteStream>.fromAddress(address).ref;
  final read = descriptor.next.asFunction<_NextDart>()(descriptor.context);
  if (read == nullptr) {
    return _NativeByteStreamReadResult(
      status: _nativeByteStreamReadError,
      bytes: Uint8List(0),
      error: 'Native byte stream returned a null read result.',
    );
  }
  try {
    final value = read.ref;
    final bytes = value.bytes.ptr == nullptr || value.bytes.len <= 0
        ? Uint8List(0)
        : Uint8List.fromList(value.bytes.ptr.asTypedList(value.bytes.len));
    final errorBytes = value.error.ptr == nullptr || value.error.len <= 0
        ? null
        : Uint8List.fromList(value.error.ptr.asTypedList(value.error.len));
    return _NativeByteStreamReadResult(
      status: value.status,
      bytes: bytes,
      error: errorBytes == null ? null : utf8.decode(errorBytes, allowMalformed: true),
    );
  } finally {
    descriptor.free_read.asFunction<_FreeReadDart>()(read);
  }
}

void _cancelDescriptor(int address) {
  final descriptor = Pointer<gen.NativeByteStream>.fromAddress(address).ref;
  if (descriptor.cancel != nullptr) {
    descriptor.cancel.asFunction<_CancelDart>()(descriptor.context);
  }
}

void _releaseDescriptor(int address, {required bool cancel}) {
  final pointer = Pointer<gen.NativeByteStream>.fromAddress(address);
  final descriptor = pointer.ref;
  if (cancel && descriptor.cancel != nullptr) {
    descriptor.cancel.asFunction<_CancelDart>()(descriptor.context);
  }
  descriptor.release.asFunction<_ReleaseDart>()(descriptor.context);
  calloc.free(pointer);
}

final class _NativeByteStreamReadResult {
  const _NativeByteStreamReadResult({
    required this.status,
    required this.bytes,
    required this.error,
  });

  final int status;
  final Uint8List bytes;
  final String? error;
}
