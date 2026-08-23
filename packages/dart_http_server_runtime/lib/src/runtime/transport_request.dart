import 'dart:typed_data';

import 'native_request.dart';

/// Transport request kind received from the native runtime.
enum TransportRequestKind { http, webSocket, webTransport }

/// Encoded request body kind received from the native transport.
enum TransportRequestBodyKind { none, text, json, multipart }

/// Low-level request passed from the native transport runtime into Dart.
///
/// Most application code should work with [RequestContext] instead of this
/// transport-facing representation.
final class TransportRequest {
  TransportRequest({
    required this.routeId,
    required this.pathParams,
    required this.query,
    required this.headers,
    this.requestKind = TransportRequestKind.http,
    this._bodyBytes,
    this.nativeBody,
    this.bodyKind = TransportRequestBodyKind.none,
  });

  /// Runtime route identifier resolved by the native router.
  final String routeId;

  /// Raw path parameter values.
  final Map<String, String> pathParams;

  /// Raw query parameters.
  final Map<String, String> query;

  /// Raw request headers.
  final Map<String, String> headers;

  /// Whether this request is a normal HTTP exchange or a WebSocket handshake.
  final TransportRequestKind requestKind;

  /// Borrowed native request body, if present.
  final NativeRequestBody? nativeBody;

  Uint8List? _bodyBytes;

  /// Raw request body bytes, if present.
  ///
  /// When the body only exists as a borrowed native view, reading this getter
  /// copies it into Dart-owned memory on first access.
  Uint8List? get bodyBytes {
    final bodyBytes = _bodyBytes;
    if (bodyBytes != null) {
      return bodyBytes;
    }

    final nativeBody = this.nativeBody;
    if (nativeBody == null) {
      return null;
    }

    final copied = nativeBody.copyBytes();
    _bodyBytes = copied;
    return copied;
  }

  /// Body kind advertised by the native transport.
  final TransportRequestBodyKind bodyKind;
}
