import 'dart:typed_data';

import 'package:dart_http_core/dart_http_core.dart';
import 'package:native_exchange/native_exchange_ffi.dart';

/// A request body whose Native Exchange ownership moves into the HTTP client.
final class NativeHttpRequestBody implements DartHttpClientNativeBody {
  NativeHttpRequestBody(this.stream, {this.contentLength, Uint8List? prefix, Uint8List? suffix})
    : prefix = prefix ?? Uint8List(0),
      suffix = suffix ?? Uint8List(0);

  final NativeByteStreamHandle stream;

  /// Bytes emitted before the first producer chunk without touching its ownership.
  final Uint8List prefix;

  /// Bytes emitted after the producer reaches end-of-stream.
  final Uint8List suffix;

  @override
  final int? contentLength;
}
