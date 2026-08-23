import 'dart:typed_data';

/// One decoded UTF-8 text field from a multipart form payload.
final class MultipartFormField {
  const MultipartFormField({required this.name, required this.value});

  /// Multipart field name from `Content-Disposition`.
  final String name;

  /// UTF-8 decoded field value.
  final String value;
}

/// One uploaded file part from a multipart form payload.
abstract interface class MultipartFile {
  /// Multipart field name from `Content-Disposition`.
  String get fieldName;

  /// Optional client-provided file name.
  String? get filename;

  /// Optional part-level content type.
  String? get contentType;

  /// Uploaded file length in bytes, when known by the runtime.
  int get length;

  /// Lazily copies the uploaded file into Dart-owned memory.
  Future<Uint8List> get bytes;

  /// Opens a stream for the uploaded file contents.
  Stream<List<int>> openRead();
}

/// Client-side file value for generated multipart request DTOs.
final class MultipartUploadFile {
  MultipartUploadFile.bytes({required List<int> bytes, this.filename, this.contentType})
    : length = bytes.length,
      _readBytes = (() async => Uint8List.fromList(bytes)),
      _openRead = null;

  MultipartUploadFile.stream({
    required Stream<List<int>> Function() openRead,
    this.filename,
    this.contentType,
    this.length,
  }) : _readBytes = (() => _collectBytes(openRead())),
       _openRead = openRead;

  /// Optional client-provided file name.
  final String? filename;

  /// Optional part-level content type.
  final String? contentType;

  /// Uploaded file length in bytes, when known without reading the stream.
  final int? length;

  final Future<Uint8List> Function() _readBytes;
  final Stream<List<int>> Function()? _openRead;

  /// Lazily reads the upload contents into memory.
  Future<Uint8List> get bytes => _readBytes();

  /// Opens a stream for the upload contents.
  Stream<List<int>> openRead() {
    final openRead = _openRead;
    if (openRead != null) {
      return openRead();
    }
    return Stream.fromFuture(bytes);
  }

  /// Attaches this upload value to a multipart form field name.
  MultipartFile asFile(String fieldName) {
    return _MultipartUploadFormFile(fieldName: fieldName, file: this);
  }
}

/// Upload progress for a generated multipart form-data request body.
final class DartHttpMultipartUploadProgress {
  const DartHttpMultipartUploadProgress({required this.bytesSent, required this.totalBytes});

  /// Multipart request body bytes emitted to the client transport.
  final int bytesSent;

  /// Total multipart request body bytes, when known before sending.
  final int? totalBytes;

  /// Completed upload fraction, or `null` when [totalBytes] is unknown.
  double? get fraction {
    final totalBytes = this.totalBytes;
    if (totalBytes == null || totalBytes == 0) {
      return null;
    }
    return bytesSent / totalBytes;
  }
}

/// Returns the known byte length for a multipart file, or `null` when the
/// client-side upload source cannot report one without reading the stream.
int? knownMultipartFileLength(MultipartFile file) {
  if (file is _MultipartUploadFormFile) {
    return file.file.length;
  }
  return file.length;
}

/// Parsed multipart form-data payload.
final class MultipartFormData {
  MultipartFormData({
    required Iterable<MultipartFormField> fields,
    required Iterable<MultipartFile> files,
  }) : fields = List.unmodifiable(fields),
       files = List.unmodifiable(files);

  /// Decoded UTF-8 text fields.
  final List<MultipartFormField> fields;

  /// Uploaded file parts.
  final List<MultipartFile> files;

  /// Returns every text field value for [name].
  Iterable<String> fieldValues(String name) sync* {
    for (final field in fields) {
      if (field.name == name) {
        yield field.value;
      }
    }
  }

  /// Returns the first text field value for [name], if present.
  String? fieldValue(String name) {
    for (final value in fieldValues(name)) {
      return value;
    }
    return null;
  }

  /// Returns every file uploaded for [name].
  Iterable<MultipartFile> filesNamed(String name) sync* {
    for (final file in files) {
      if (file.fieldName == name) {
        yield file;
      }
    }
  }

  /// Returns the first file uploaded for [name], if present.
  MultipartFile? file(String name) {
    for (final file in filesNamed(name)) {
      return file;
    }
    return null;
  }
}

final class _MultipartUploadFormFile implements MultipartFile {
  const _MultipartUploadFormFile({required this.fieldName, required this.file});

  @override
  final String fieldName;

  final MultipartUploadFile file;

  @override
  String? get filename => file.filename;

  @override
  String? get contentType => file.contentType;

  @override
  int get length => file.length ?? 0;

  @override
  Future<Uint8List> get bytes => file.bytes;

  @override
  Stream<List<int>> openRead() => file.openRead();
}

Future<Uint8List> _collectBytes(Stream<List<int>> stream) async {
  final chunks = <List<int>>[];
  var length = 0;
  await for (final chunk in stream) {
    chunks.add(chunk);
    length += chunk.length;
  }
  final bytes = Uint8List(length);
  var offset = 0;
  for (final chunk in chunks) {
    bytes.setRange(offset, offset + chunk.length, chunk);
    offset += chunk.length;
  }
  return bytes;
}
