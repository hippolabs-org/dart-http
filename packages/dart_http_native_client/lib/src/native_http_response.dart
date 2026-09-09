import 'package:native_exchange/native_exchange_ffi.dart';

/// Streamed response metadata plus zero-copy native response chunks.
final class NativeHttpLeasedStreamedResponse {
  const NativeHttpLeasedStreamedResponse({
    required this.status,
    required this.contentType,
    required this.headers,
    required this.bodyStream,
  });

  final int status;
  final String contentType;
  final Map<String, String> headers;

  /// Each chunk owns its native payload and must be closed by the consumer.
  final Stream<NativeBufferLease> bodyStream;
}

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
