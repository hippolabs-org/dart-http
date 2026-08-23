import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../http.dart';
import '../web_socket.dart';
import '../web_transport.dart';

/// One outbound request emitted by a generated client.
final class DartHttpClientRequest {
  const DartHttpClientRequest({
    required this.method,
    required this.uri,
    this.headers = const <String, String>{},
    this.body,
    this.bodyBytes,
    this.bodyStream,
    this.bodyStreamLength,
    this.abortTrigger,
  }) : assert(
         bodyStream == null || (body == null && bodyBytes == null),
         'bodyStream cannot be combined with body or bodyBytes.',
       );

  final HttpMethod method;
  final Uri uri;
  final Map<String, String> headers;
  final String? body;
  final List<int>? bodyBytes;
  final Stream<List<int>>? bodyStream;
  final int? bodyStreamLength;
  final Future<void>? abortTrigger;

  DartHttpClientRequest copyWith({
    HttpMethod? method,
    Uri? uri,
    Map<String, String>? headers,
    String? body,
    List<int>? bodyBytes,
    Stream<List<int>>? bodyStream,
    int? bodyStreamLength,
    Future<void>? abortTrigger,
  }) {
    return DartHttpClientRequest(
      method: method ?? this.method,
      uri: uri ?? this.uri,
      headers: headers ?? this.headers,
      body: body ?? this.body,
      bodyBytes: bodyBytes ?? this.bodyBytes,
      bodyStream: bodyStream ?? this.bodyStream,
      bodyStreamLength: bodyStreamLength ?? this.bodyStreamLength,
      abortTrigger: abortTrigger ?? this.abortTrigger,
    );
  }
}

/// One inbound response returned to a generated client.
final class DartHttpClientResponse {
  const DartHttpClientResponse({
    required this.status,
    required this.contentType,
    this.headers = const <String, String>{},
    this._body,
    this._bodyBytes,
  });

  final int status;
  final String contentType;
  final Map<String, String> headers;
  final String? _body;
  final List<int>? _bodyBytes;

  /// Response body decoded as UTF-8 text.
  String get body {
    final body = _body;
    if (body != null) {
      return body;
    }
    return utf8.decode(bodyBytes, allowMalformed: true);
  }

  /// Raw response body bytes.
  Uint8List get bodyBytes {
    final bytes = _bodyBytes;
    if (bytes != null) {
      return Uint8List.fromList(bytes);
    }
    return Uint8List.fromList(utf8.encode(_body ?? ''));
  }
}

/// One inbound streaming response returned to a generated client.
final class DartHttpClientStreamedResponse {
  const DartHttpClientStreamedResponse({
    required this.status,
    required this.contentType,
    this.headers = const <String, String>{},
    required this.bodyStream,
  });

  final int status;
  final String contentType;
  final Map<String, String> headers;
  final Stream<List<int>> bodyStream;
}

/// Transport abstraction used by generated clients.
abstract interface class HttpClientTransport {
  Future<DartHttpClientResponse> send(DartHttpClientRequest request);

  Future<DartHttpClientStreamedResponse> sendStream(DartHttpClientRequest request);
}

/// One outbound WebSocket connection request emitted by a generated client.
final class DartHttpClientWebSocketRequest {
  const DartHttpClientWebSocketRequest({
    required this.uri,
    this.headers = const <String, String>{},
    this.protocols = const <String>[],
  });

  final Uri uri;
  final Map<String, String> headers;
  final List<String> protocols;
}

/// Active WebSocket connection returned by a generated client.
abstract interface class DartHttpClientWebSocket {
  Stream<WebSocketMessage> get messages;

  Future<void> sendText(String value);

  Future<void> sendBinary(List<int> value);

  Future<void> sendJson(Object? value);

  Future<void> close([int? code, String? reason]);
}

/// Transport abstraction used by generated WebSocket client methods.
abstract interface class DartHttpClientWebSocketTransport {
  Future<DartHttpClientWebSocket> connect(DartHttpClientWebSocketRequest request);
}

/// One outbound WebTransport connection request emitted by a generated client.
final class DartHttpClientWebTransportRequest {
  const DartHttpClientWebTransportRequest({
    required this.uri,
    this.headers = const <String, String>{},
  });

  final Uri uri;
  final Map<String, String> headers;
}

/// Active WebTransport session returned by a generated client.
abstract interface class DartHttpClientWebTransportSession {
  Stream<Uint8List> get datagrams;

  IncomingWebTransportReceiveStreams get incomingStreams;

  Future<WebTransportSendStream> openUnidirectionalStream({int? sendOrder});

  Future<WebTransportBidirectionalStream> openBidirectionalStream({int? sendOrder});

  /// Complete incoming unidirectional stream payloads.
  ///
  /// This compatibility surface must not be listened to at the same time as
  /// [incomingStreams].
  Stream<Uint8List> get streams;

  Future<void> sendDatagram(List<int> value);

  /// Sends one complete payload on a new unidirectional stream.
  Future<void> sendStream(List<int> value);

  Future<void> close([int? code, String? reason]);
}

/// Transport abstraction used by generated WebTransport client methods.
abstract interface class DartHttpClientWebTransportTransport {
  Future<DartHttpClientWebTransportSession> connect(DartHttpClientWebTransportRequest request);
}

/// Raised when a response does not match the generated route contract.
final class DartHttpClientResponseException implements Exception {
  const DartHttpClientResponseException({
    required this.method,
    required this.uri,
    required this.expectedStatus,
    required this.actualStatus,
    required this.body,
  });

  final HttpMethod method;
  final Uri uri;
  final int expectedStatus;
  final int actualStatus;
  final String body;

  @override
  String toString() {
    return 'DartHttpClientResponseException('
        'method: $method, '
        'uri: $uri, '
        'expectedStatus: $expectedStatus, '
        'actualStatus: $actualStatus, '
        'body: $body'
        ')';
  }
}
