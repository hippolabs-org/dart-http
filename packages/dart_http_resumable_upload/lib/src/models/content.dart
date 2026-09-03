import 'package:dart_http_core/dart_http_core.dart';

/// One request body being appended to an upload resource.
final class ResumableUploadContent {
  const ResumableUploadContent.buffered(Stream<List<int>> stream, {required this.length})
    : _stream = stream,
      nativeStream = null;

  const ResumableUploadContent.native(this.nativeStream, {required this.length}) : _stream = null;

  final Stream<List<int>>? _stream;

  /// Runtime-native stream that can be adopted without copying bytes to Dart.
  final DartHttpServerNativeBodyStream? nativeStream;

  /// Declared request content length.
  final int length;

  bool get isNative => nativeStream != null;

  /// Buffered Dart stream, when this content did not arrive natively.
  Stream<List<int>> get stream {
    return _stream ??
        (throw StateError('Native upload content must be consumed by a native-capable store.'));
  }
}
