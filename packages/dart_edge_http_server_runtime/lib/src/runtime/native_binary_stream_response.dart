import 'package:dart_edge_core/dart_edge_core.dart';
import 'package:dart_edge_native_bridge/dart_edge_native_bridge.dart';

/// Binary HTTP response whose body remains native from producer to socket.
final class NativeBinaryStreamResponse {
  const NativeBinaryStreamResponse({
    required this.body,
    required this.contentType,
    this.status = 200,
    this.contentLength,
    this.headers = const <HttpHeader>[],
  }) : assert(contentLength == null || contentLength >= 0);

  /// Creates a native `206 Partial Content` response for [range].
  factory NativeBinaryStreamResponse.partial({
    required NativeByteStreamHandle body,
    required String contentType,
    required HttpByteRangeSelection range,
    List<HttpHeader> headers = const <HttpHeader>[],
  }) {
    return NativeBinaryStreamResponse(
      body: body,
      contentType: contentType,
      status: 206,
      contentLength: range.contentLength,
      headers: [...headers, ...range.responseHeaders],
    );
  }

  /// Single-owner native body transferred to the HTTP runtime.
  final NativeByteStreamHandle body;

  final int status;
  final String contentType;
  final int? contentLength;
  final List<HttpHeader> headers;
}
