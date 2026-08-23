import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'generated_bindings.dart';

typedef NativeStringPair = ({String key, String value});

Uint8List? maybeCopyNativeBytes(NativeBytes value) {
  if (value.len == 0 || value.ptr == nullptr) {
    return null;
  }

  return Uint8List.fromList(value.ptr.asTypedList(value.len));
}

Uint8List copyNativeOwnedBytes(NativeOwnedBytes value) {
  if (value.len == 0 || value.ptr == nullptr) {
    return Uint8List(0);
  }

  return Uint8List.fromList(value.ptr.asTypedList(value.len));
}

String decodeNativeUtf8(NativeBytes value, {bool allowMalformed = true}) {
  final bytes = maybeCopyNativeBytes(value);
  if (bytes == null || bytes.isEmpty) {
    return '';
  }

  return utf8.decode(bytes, allowMalformed: allowMalformed);
}

List<NativeStringPair> copyNativePairs(
  Pointer<NativePair> pairs,
  int count, {
  bool allowMalformed = true,
}) {
  if (count == 0 || pairs == nullptr) {
    return const <NativeStringPair>[];
  }

  return [
    for (var index = 0; index < count; index += 1)
      (
        key: decodeNativeUtf8((pairs + index).ref.key, allowMalformed: allowMalformed),
        value: decodeNativeUtf8((pairs + index).ref.value, allowMalformed: allowMalformed),
      ),
  ];
}

/// Tracks native allocations that should be released together after one FFI
/// call completes.
final class NativeAllocations {
  final _strings = <Pointer<Utf8>>[];
  final _allocations = <Pointer<NativeType>>[];

  /// Allocates [value] as a NUL-terminated UTF-8 string.
  Pointer<Char> requiredString(String value) {
    return _string(value);
  }

  /// Allocates [value] as UTF-8, or returns `nullptr` for absent values.
  Pointer<Char> optionalString(String? value) {
    if (value == null) {
      return nullptr;
    }
    return _string(value);
  }

  /// Tracks a caller-owned allocation so [free] can release it with the rest
  /// of this scope.
  Pointer<T> track<T extends NativeType>(Pointer<T> pointer) {
    if (pointer != nullptr) {
      _allocations.add(pointer);
    }
    return pointer;
  }

  /// Tracks a package-specific native string pair array and returns a holder
  /// that carries the pointer and count together.
  NativeStringPairs<T> trackStringPairs<T extends NativeType>(Pointer<T> pointer, int length) {
    return NativeStringPairs<T>(pointer: track(pointer), length: length);
  }

  /// Frees all tracked allocations.
  void free() {
    for (final pointer in _allocations.reversed) {
      calloc.free(pointer);
    }
    for (final pointer in _strings.reversed) {
      calloc.free(pointer);
    }
    _allocations.clear();
    _strings.clear();
  }

  Pointer<Char> _string(String value) {
    final pointer = value.toNativeUtf8();
    _strings.add(pointer);
    return pointer.cast<Char>();
  }
}

/// Pointer and element count for a native string pair array.
final class NativeStringPairs<T extends NativeType> {
  const NativeStringPairs({required this.pointer, required this.length});

  final Pointer<T> pointer;
  final int length;
}

String requiredNativeString(Pointer<Char> pointer, String name) {
  final value = optionalNativeString(pointer);
  if (value == null) {
    throw StateError('Native result omitted $name.');
  }
  return value;
}

String? optionalNativeString(Pointer<Char> pointer) {
  if (pointer == nullptr) {
    return null;
  }
  return pointer.cast<Utf8>().toDartString();
}
