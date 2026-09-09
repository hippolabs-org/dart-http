import 'package:native_exchange/native_exchange_ffi.dart';

/// Buffered response metadata plus a single-owner native body allocation.
final class NativeHttpBufferedResponse {
  const NativeHttpBufferedResponse({
    required this.status,
    required this.contentType,
    required this.headers,
    required this.body,
  });

  final int status;
  final String contentType;
  final Map<String, String> headers;
  final NativeBufferLease body;

  /// Releases the response body when ownership was not transferred elsewhere.
  void close() => body.close();
}

/// Response metadata plus a single-owner native response body.
final class NativeHttpResponse {
  const NativeHttpResponse({
    required this.status,
    required this.contentType,
    required this.headers,
    required this.body,
  });

  final int status;
  final String contentType;
  final Map<String, String> headers;
  final NativeByteStreamHandle body;
}
