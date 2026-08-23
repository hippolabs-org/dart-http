import 'package:native_exchange/native_exchange_ffi.dart';

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
