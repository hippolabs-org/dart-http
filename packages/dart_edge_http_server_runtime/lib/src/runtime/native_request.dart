import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:dart_edge_core/dart_edge_core.dart';
import 'package:dart_edge_native_bridge/dart_edge_native_bridge.dart' as core_ffi;
import 'package:ffi/ffi.dart';

/// Borrowed native request body view for the current request lifecycle.
///
/// This type does not own the underlying memory. It is only valid while the
/// current request is still being handled by the runtime.
final class NativeRequestBody {
  NativeRequestBody._(Pointer<Uint8> ptr, int length, this._liveness)
    : _ptr = ptr,
      _length = length {
    _nativeBytesStorage = calloc<core_ffi.NativeBytes>()
      ..ref.ptr = ptr
      ..ref.len = length;
    _liveness.addCleanup(() => calloc.free(_nativeBytesStorage));
  }

  final Pointer<Uint8> _ptr;
  final int _length;
  final _NativeRequestLiveness _liveness;
  late final Pointer<core_ffi.NativeBytes> _nativeBytesStorage;

  /// Borrowed native byte view for the current request.
  core_ffi.NativeBytes get nativeBytes {
    _liveness.ensureActive();
    return _nativeBytesStorage.ref;
  }

  /// Length of the borrowed request body in bytes.
  int get length {
    _liveness.ensureActive();
    return _length;
  }

  /// Whether the borrowed request body is empty.
  bool get isEmpty => length == 0;

  /// Throws if the underlying native body is no longer available.
  void ensureActive() {
    _liveness.ensureActive();
  }

  /// Copies the borrowed native body into Dart-owned memory.
  Uint8List copyBytes() {
    _liveness.ensureActive();
    if (_length == 0 || _ptr == nullptr) {
      return Uint8List(0);
    }
    return Uint8List.fromList(_ptr.asTypedList(_length));
  }
}

({NativeRequestBody body, void Function() release}) createBorrowedNativeRequestBody(
  core_ffi.NativeBytes bytes,
) {
  final liveness = _NativeRequestLiveness();
  return (body: NativeRequestBody._(bytes.ptr, bytes.len, liveness), release: liveness.release);
}

NativeRequestBody borrowNativeRequestBodyView(
  core_ffi.NativeBytes bytes,
  NativeRequestBody reference,
) {
  reference.ensureActive();
  return NativeRequestBody._(bytes.ptr, bytes.len, reference._liveness);
}

/// One decoded text field from a multipart form payload.
final class NativeMultipartField {
  const NativeMultipartField({required this.name, required this.value});

  /// Multipart field name from `Content-Disposition`.
  final String name;

  /// UTF-8 decoded field value.
  final String value;
}

/// One uploaded file entry from a multipart form payload.
final class NativeMultipartFile implements MultipartFile {
  const NativeMultipartFile({
    required this.fieldName,
    this.filename,
    this.contentType,
    required this.body,
  });

  /// Multipart field name from `Content-Disposition`.
  @override
  final String fieldName;

  /// Optional client-provided file name.
  @override
  final String? filename;

  /// Optional part-level content type.
  @override
  final String? contentType;

  /// Borrowed native file body for the current request lifecycle.
  final NativeRequestBody body;

  /// Length of the uploaded file in bytes.
  @override
  int get length => body.length;

  /// Lazily copies the uploaded file into Dart-owned memory.
  @override
  Future<Uint8List> get bytes async => copyBytes();

  /// Opens the uploaded file as a single-chunk stream.
  @override
  Stream<List<int>> openRead() async* {
    yield copyBytes();
  }

  /// Borrowed native bytes for the uploaded file.
  core_ffi.NativeBytes get nativeBytes => body.nativeBytes;

  /// Copies the uploaded file into Dart-owned memory.
  Uint8List copyBytes() => body.copyBytes();
}

/// Borrowed multipart form view for one request.
final class NativeMultipartForm {
  NativeMultipartForm({
    required Iterable<NativeMultipartField> fields,
    required Iterable<NativeMultipartFile> files,
  }) : fields = List.unmodifiable(fields),
       files = List.unmodifiable(files);

  /// Decoded UTF-8 text fields from the multipart form.
  final List<NativeMultipartField> fields;

  /// Uploaded files from the multipart form.
  final List<NativeMultipartFile> files;

  /// Returns the first field value for [name], if present.
  String? fieldValue(String name) {
    for (final field in fields) {
      if (field.name == name) {
        return field.value;
      }
    }
    return null;
  }

  /// Returns every file uploaded for [name].
  Iterable<NativeMultipartFile> filesNamed(String name) sync* {
    for (final file in files) {
      if (file.fieldName == name) {
        yield file;
      }
    }
  }

  /// Adapts this runtime-native form view to the core multipart contract.
  MultipartFormData toMultipartFormData() {
    return MultipartFormData(
      fields: fields.map((field) => MultipartFormField(name: field.name, value: field.value)),
      files: files,
    );
  }
}

typedef MultipartLoader = Future<NativeMultipartForm> Function();

/// Low-level native request view for the current handler lifecycle.
final class NativeRequest {
  NativeRequest({
    required this.routeId,
    required Map<String, String> pathParams,
    required Map<String, String> query,
    required Map<String, String> headers,
    this.body,
    this._multipartLoader,
  }) : pathParams = Map.unmodifiable(pathParams),
       query = Map.unmodifiable(query),
       headers = Map.unmodifiable(headers);

  /// Runtime route identifier resolved by the native router.
  final String routeId;

  /// Raw path parameter values.
  final Map<String, String> pathParams;

  /// Raw query values.
  final Map<String, String> query;

  /// Raw request headers.
  final Map<String, String> headers;

  /// Borrowed native request body, if present.
  final NativeRequestBody? body;

  final MultipartLoader? _multipartLoader;
  Future<NativeMultipartForm>? _multipartFuture;

  /// Parses the current request body as `multipart/form-data`.
  ///
  /// The returned fields and files stay valid only while the request is still
  /// being handled by the runtime.
  Future<NativeMultipartForm> multipart() {
    final body = this.body;
    if (body == null) {
      throw StateError('This request does not have a native request body.');
    }
    body.ensureActive();

    final multipartLoader = _multipartLoader;
    if (multipartLoader == null) {
      throw StateError('This request does not expose multipart/form-data parsing.');
    }

    return _multipartFuture ??= multipartLoader();
  }
}

final class _NativeRequestLiveness {
  var _released = false;
  final List<void Function()> _cleanup = <void Function()>[];

  void ensureActive() {
    if (_released) {
      throw StateError(
        'The borrowed native request body is no longer available after '
        'request handling completes.',
      );
    }
  }

  void addCleanup(void Function() cleanup) {
    if (_released) {
      cleanup();
      return;
    }
    _cleanup.add(cleanup);
  }

  void release() {
    if (_released) {
      return;
    }
    _released = true;
    for (final cleanup in _cleanup.reversed) {
      cleanup();
    }
    _cleanup.clear();
  }
}
