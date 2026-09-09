import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:native_exchange/native_exchange.dart';

import '../http.dart';
import '../web_socket.dart';
import '../web_transport.dart';

/// Marker implemented by transport-specific, ownership-transferring bodies.
///
/// The core contract deliberately does not import `dart:ffi`, so it remains
/// usable on the web. Native transports may expose a concrete implementation
/// backed by Native Exchange.
abstract interface class DartHttpClientNativeBody {
  /// Declared byte length, when known.
  int? get contentLength;
}

/// Describes how a generated client consumes the response body.
///
/// Transports use [serverSentEvents] to apply the HTTP semantics required for
/// incremental event delivery, rather than treating the request as a generic
/// byte stream.
enum DartHttpClientResponseMode {
  /// Collects the response body before decoding it.
  buffered,

  /// Delivers a generic response body incrementally.
  stream,

  /// Delivers a `text/event-stream` response incrementally.
  serverSentEvents,
}

/// One outbound request emitted by a generated client.
final class DartHttpClientRequest {
  const DartHttpClientRequest({
    required this.method,
    required this.uri,
    this.headers = const <String, String>{},
    this.body,
    this.bodyBytes,
    this.bodyLease,
    this.bodyStream,
    this.bodyStreamLength,
    this.nativeBody,
    this.abortTrigger,
    this.responseMode = DartHttpClientResponseMode.buffered,
  }) : assert(
         bodyStream == null || (body == null && bodyBytes == null && bodyLease == null),
         'bodyStream cannot be combined with another request body.',
       ),
       assert(
         bodyLease == null || (body == null && bodyBytes == null && bodyStream == null),
         'bodyLease cannot be combined with another request body.',
       ),
       assert(
         nativeBody == null ||
             (body == null && bodyBytes == null && bodyLease == null && bodyStream == null),
         'nativeBody cannot be combined with another request body.',
       );

  final HttpMethod method;
  final Uri uri;
  final Map<String, String> headers;
  final String? body;
  final List<int>? bodyBytes;

  /// Single-owner request bytes that the transport must consume or release.
  final ByteLease? bodyLease;
  final Stream<List<int>>? bodyStream;
  final int? bodyStreamLength;
  final DartHttpClientNativeBody? nativeBody;
  final Future<void>? abortTrigger;

  /// Expected response delivery semantics.
  final DartHttpClientResponseMode responseMode;

  DartHttpClientRequest copyWith({
    HttpMethod? method,
    Uri? uri,
    Map<String, String>? headers,
    String? body,
    List<int>? bodyBytes,
    ByteLease? bodyLease,
    Stream<List<int>>? bodyStream,
    int? bodyStreamLength,
    DartHttpClientNativeBody? nativeBody,
    Future<void>? abortTrigger,
    DartHttpClientResponseMode? responseMode,
  }) {
    return DartHttpClientRequest(
      method: method ?? this.method,
      uri: uri ?? this.uri,
      headers: headers ?? this.headers,
      body: body ?? this.body,
      bodyBytes: bodyBytes ?? this.bodyBytes,
      bodyLease: bodyLease ?? this.bodyLease,
      bodyStream: bodyStream ?? this.bodyStream,
      bodyStreamLength: bodyStreamLength ?? this.bodyStreamLength,
      nativeBody: nativeBody ?? this.nativeBody,
      abortTrigger: abortTrigger ?? this.abortTrigger,
      responseMode: responseMode ?? this.responseMode,
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
  }) : _storage = null;

  /// Creates a response that already owns its Dart byte representation.
  DartHttpClientResponse.ownedBytes({
    required this.status,
    required this.contentType,
    this.headers = const <String, String>{},
    required Uint8List bodyBytes,
  }) : _body = null,
       _bodyBytes = null,
       _storage = _DartHttpClientResponseBodyStorage.dartBytes(bodyBytes);

  /// Creates a response whose bytes remain leased until materialized or closed.
  DartHttpClientResponse.leased({
    required this.status,
    required this.contentType,
    this.headers = const <String, String>{},
    required ByteLease body,
  }) : _body = null,
       _bodyBytes = null,
       _storage = _DartHttpClientResponseBodyStorage.leased(body);

  final int status;
  final String contentType;
  final Map<String, String> headers;
  final String? _body;
  final List<int>? _bodyBytes;
  final _DartHttpClientResponseBodyStorage? _storage;

  /// Response body decoded as UTF-8 text.
  String get body {
    final storage = _storage;
    if (storage != null) {
      return storage.text;
    }
    final body = _body;
    if (body != null) {
      return body;
    }
    return utf8.decode(bodyBytes, allowMalformed: true);
  }

  /// Raw response body bytes.
  Uint8List get bodyBytes {
    final storage = _storage;
    if (storage != null) {
      return storage.bytes;
    }
    final cached = _legacyResponseByteCache[this];
    if (cached != null) return cached;
    final bytes = _bodyBytes;
    if (bytes != null) {
      return _legacyResponseByteCache[this] = Uint8List.fromList(bytes);
    }
    return _legacyResponseByteCache[this] = Uint8List.fromList(utf8.encode(_body ?? ''));
  }

  /// Releases a native body that has not been materialized.
  void close() => _storage?.close();
}

final Expando<Uint8List> _legacyResponseByteCache = Expando<Uint8List>(
  'DartHttpClientResponse.bodyBytes',
);

final class _DartHttpClientResponseBodyStorage {
  _DartHttpClientResponseBodyStorage.dartBytes(Uint8List bytes) : _bytes = bytes, _lease = null;

  _DartHttpClientResponseBodyStorage.leased(ByteLease lease) : _lease = lease;

  ByteLease? _lease;
  Uint8List? _bytes;
  String? _text;
  bool _closed = false;

  String get text {
    final text = _text;
    if (text != null) return text;
    final ownedBytes = _bytes;
    if (ownedBytes != null) {
      return _text = utf8.decode(ownedBytes, allowMalformed: true);
    }
    if (_closed) throw StateError('HTTP response body is closed.');
    final bytes = _lease?.bytesView ?? Uint8List(0);
    return _text = utf8.decode(bytes, allowMalformed: true);
  }

  Uint8List get bytes {
    final bytes = _bytes;
    if (bytes != null) return bytes;
    if (_closed) throw StateError('HTTP response body is closed.');
    final lease = _lease;
    if (lease != null) {
      _lease = null;
      return _bytes = lease.takeDartBytes();
    }
    return _bytes = Uint8List.fromList(utf8.encode(_text ?? ''));
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _lease?.close();
    _lease = null;
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

  /// Sends one binary frame.
  ///
  /// The returned future completes only after the transport no longer reads
  /// [value]. It does not imply that the peer received or acknowledged the
  /// frame.
  Future<void> sendBinary(List<int> value);

  Future<void> sendJson(Object? value);

  Future<void> close([int? code, String? reason]);
}

/// Details supplied by the peer when it closes a WebSocket connection.
final class DartHttpClientWebSocketCloseDetails {
  const DartHttpClientWebSocketCloseDetails({this.code, this.reason});

  final int? code;
  final String? reason;
}

/// Optional WebSocket capability exposing the peer's terminal close frame.
///
/// [closeDetails] remains `null` until a close frame is received. Transport
/// failures that terminate without a close frame leave it `null`.
abstract interface class DartHttpClientCloseAwareWebSocket implements DartHttpClientWebSocket {
  DartHttpClientWebSocketCloseDetails? get closeDetails;
}

/// Optional WebSocket capability for consuming binary payload ownership.
///
/// Implementations may transfer native payloads directly into their outbound
/// queue. The lease is consumed whether the send succeeds or fails. The
/// returned future completes once the transport no longer borrows the payload,
/// not when the peer acknowledges it.
abstract interface class DartHttpClientOwnedWebSocket implements DartHttpClientWebSocket {
  /// Sends [prefix] followed by [lease] as one logical binary message.
  ///
  /// Native transports may use WebSocket fragmentation so the payload can be
  /// transferred without concatenating it into another Dart buffer. [prefix]
  /// must remain unchanged until the returned future completes.
  Future<void> sendBinaryLease(BinaryPayloadLease lease, {List<int> prefix = const <int>[]});
}

/// Optional WebSocket capability for base64-encoding an owned binary payload
/// directly into a text message.
///
/// Native transports can use this to avoid materializing the base64 value and
/// enclosing text message as Dart strings. The lease is consumed whether the
/// send succeeds or fails.
abstract interface class DartHttpClientBase64TextWebSocket implements DartHttpClientWebSocket {
  /// Sends [prefix], the standard padded base64 encoding of [lease], and
  /// [suffix] as one logical WebSocket text message.
  ///
  /// The returned future completes once the transport no longer owns the
  /// payload, not when the peer acknowledges it.
  Future<void> sendTextBase64Lease(
    BinaryPayloadLease lease, {
    String prefix = '',
    String suffix = '',
    int offset = 0,
    int? length,
  });
}

/// Optional native WebSocket capability for bounded, synchronous lease enqueueing.
///
/// [enqueueBinaryLease] transfers payload ownership into the transport without
/// waiting for a socket write. [flush] is an ordered fence: it completes after
/// every message enqueued before it has been flushed by the transport. Neither
/// operation implies peer receipt or acknowledgement.
abstract interface class DartHttpClientQueuedWebSocket implements DartHttpClientOwnedWebSocket {
  /// Enqueues an existing Native Exchange [lease] without an adapter object.
  ///
  /// The lease is consumed on both success and failure. Implementations must
  /// throw synchronously when their bounded outbound payload queue is full.
  void enqueueByteLease(ByteLease lease, {List<int> prefix = const <int>[]});

  /// Enqueues [prefix] and [lease] as one logical binary message.
  ///
  /// The lease is consumed on both success and failure. Implementations must
  /// throw synchronously when their bounded outbound payload queue is full.
  void enqueueBinaryLease(BinaryPayloadLease lease, {List<int> prefix = const <int>[]});

  /// Base64-encodes [lease] between [prefix] and [suffix] and enqueues the
  /// resulting text message without creating a per-message completion.
  ///
  /// The lease is consumed on both success and failure. Implementations must
  /// throw synchronously when their bounded outbound payload queue is full.
  void enqueueTextBase64Lease(
    BinaryPayloadLease lease, {
    String prefix = '',
    String suffix = '',
    int offset = 0,
    int? length,
  });

  /// Waits until all messages enqueued before this call have been flushed.
  Future<void> flush();
}

/// A native byte stream drained by a WebSocket without a Dart object or
/// native-to-Dart completion for each chunk.
abstract interface class DartHttpClientNativeWebSocketByteStream {
  /// Starts routing chunks with [prefix]. The native sender writes a
  /// zero-based chunk sequence and payload unit count into the prefix when the
  /// corresponding offsets are non-negative.
  ///
  /// Both fields use big-endian encoding. Sequence occupies eight bytes and
  /// payload unit count occupies four. [bytesPerPayloadUnit] lets callers
  /// express samples or frames instead of raw bytes.
  void resume({
    List<int> prefix = const <int>[],
    int sequenceOffset = -1,
    int payloadUnitCountOffset = -1,
    int bytesPerPayloadUnit = 1,
  });

  /// Pauses pulls and completes after previously accepted chunks are flushed.
  Future<DartHttpClientNativeWebSocketByteStreamStats> pauseAndFlush();

  /// Keeps pulling until the producer reaches EOF, then completes after every
  /// accepted chunk has been flushed to the WebSocket writer.
  Future<DartHttpClientNativeWebSocketByteStreamStats> drainAndFlush();

  /// Cancels and releases the adopted producer stream natively.
  void close();
}

/// A native byte stream encoded and framed as one WebSocket text message per
/// producer chunk without exposing those chunks to Dart.
abstract interface class DartHttpClientNativeWebSocketBase64TextStream {
  /// Starts routing chunks as [prefix] + padded base64 + [suffix].
  void resume({String prefix = '', String suffix = ''});

  /// Pauses pulls and completes after previously accepted chunks are flushed.
  Future<DartHttpClientNativeWebSocketByteStreamStats> pauseAndFlush();

  /// Keeps pulling until the producer reaches EOF, then completes after every
  /// accepted chunk has been flushed to the WebSocket writer.
  Future<DartHttpClientNativeWebSocketByteStreamStats> drainAndFlush();

  /// Cancels and releases the adopted producer stream natively.
  void close();
}

/// Counters for the segment completed by a native byte-stream boundary fence.
final class DartHttpClientNativeWebSocketByteStreamStats {
  const DartHttpClientNativeWebSocketByteStreamStats({
    required this.chunkCount,
    required this.byteCount,
  });

  final int chunkCount;
  final int byteCount;
}

/// WebSocket capability for adopting one Native Exchange byte stream.
abstract interface class DartHttpClientNativeStreamWebSocket
    implements DartHttpClientQueuedWebSocket {
  /// Transfers [stream] into a paused native WebSocket pump.
  DartHttpClientNativeWebSocketByteStream adoptByteStream(ByteStreamLease stream);

  /// Transfers [stream] into a paused native base64-text WebSocket pump.
  DartHttpClientNativeWebSocketBase64TextStream adoptBase64TextStream(ByteStreamLease stream);
}

/// Ownership-aware binary sending for every client WebSocket.
///
/// Native transports can implement [DartHttpClientOwnedWebSocket] to avoid a
/// Dart byte copy. Other transports use [DartHttpClientWebSocket.sendBinary]
/// and release the lease after that operation no longer reads its view.
extension DartHttpClientWebSocketOwnedSending on DartHttpClientWebSocket {
  Future<void> sendBinaryLease(BinaryPayloadLease lease, {List<int> prefix = const <int>[]}) async {
    final socket = this;
    if (socket is DartHttpClientOwnedWebSocket) {
      await socket.sendBinaryLease(lease, prefix: prefix);
      return;
    }
    try {
      if (prefix.isEmpty) {
        await sendBinary(lease.bytesView);
      } else {
        final combined = Uint8List(prefix.length + lease.length)
          ..setRange(0, prefix.length, prefix)
          ..setRange(prefix.length, prefix.length + lease.length, lease.bytesView);
        await sendBinary(combined);
      }
    } finally {
      lease.close();
    }
  }

  /// Sends a base64 value inside a text message while consuming [lease].
  ///
  /// Native transports may encode directly from transferred native storage.
  /// Other transports use a portable Dart base64 encoding fallback.
  Future<void> sendTextBase64Lease(
    BinaryPayloadLease lease, {
    String prefix = '',
    String suffix = '',
    int offset = 0,
    int? length,
  }) async {
    final socket = this;
    if (socket is DartHttpClientBase64TextWebSocket) {
      await socket.sendTextBase64Lease(
        lease,
        prefix: prefix,
        suffix: suffix,
        offset: offset,
        length: length,
      );
      return;
    }
    try {
      final selectedLength = length ?? lease.length - offset;
      RangeError.checkValidRange(offset, offset + selectedLength, lease.length, 'offset');
      final bytes = Uint8List.sublistView(lease.bytesView, offset, offset + selectedLength);
      await sendText('$prefix${base64Encode(bytes)}$suffix');
    } finally {
      lease.close();
    }
  }
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
