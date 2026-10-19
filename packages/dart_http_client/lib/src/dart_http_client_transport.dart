import 'package:dart_http_core/dart_http_core.dart';
import 'package:http/http.dart' as http;

import 'upload_progress_stub.dart'
    if (dart.library.js_interop) 'upload_progress_web.dart'
    as upload_progress;

typedef DartHttpClientSend = Future<DartHttpClientResponse> Function(DartHttpClientRequest request);

typedef DartHttpClientInterceptor = Future<DartHttpClientResponse> Function(
  DartHttpClientRequest request,
  DartHttpClientSend next,
);

typedef DartHttpClientStreamedSend = Future<DartHttpClientStreamedResponse> Function(
  DartHttpClientRequest request,
);

typedef DartHttpClientStreamedInterceptor = Future<DartHttpClientStreamedResponse> Function(
  DartHttpClientRequest request,
  DartHttpClientStreamedSend next,
);

/// Sends generated client requests through `package:http`.
final class DartHttpClientTransport implements HttpClientTransport {
  DartHttpClientTransport({
    http.Client? client,
    this.browserUploadWithCredentials = false,
    List<DartHttpClientInterceptor> interceptors = const [],
    List<DartHttpClientStreamedInterceptor> streamedInterceptors = const [],
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _interceptors = List<DartHttpClientInterceptor>.unmodifiable(interceptors),
       _streamedInterceptors = List<DartHttpClientStreamedInterceptor>.unmodifiable(
         streamedInterceptors,
       );

  /// Credential mode for browser XHR requests with upload progress. Those
  /// requests use XHR instead of the injected package:http client.
  final bool browserUploadWithCredentials;
  final _uploadAborts = <void Function()>{};
  var _closed = false;
  final http.Client _client;
  final bool _ownsClient;
  final List<DartHttpClientInterceptor> _interceptors;
  final List<DartHttpClientStreamedInterceptor> _streamedInterceptors;

  @override
  Future<DartHttpClientResponse> send(DartHttpClientRequest request) {
    DartHttpClientSend next = _sendWithoutInterceptors;
    for (final interceptor in _interceptors.reversed) {
      final current = next;
      next = (request) => interceptor(request, current);
    }
    return next(request);
  }

  @override
  Future<DartHttpClientStreamedResponse> sendStream(DartHttpClientRequest request) {
    DartHttpClientStreamedSend next = _sendStreamWithoutInterceptors;
    for (final interceptor in _streamedInterceptors.reversed) {
      final current = next;
      next = (request) => interceptor(request, current);
    }
    return next(request);
  }

  Future<DartHttpClientResponse> _sendWithoutInterceptors(DartHttpClientRequest request) async {
    final streamed = await _sendStreamWithoutInterceptors(request);
    final responseBytes = await http.ByteStream(streamed.bodyStream).toBytes();
    return DartHttpClientResponse.ownedBytes(
      status: streamed.status,
      contentType: streamed.contentType,
      headers: streamed.headers,
      bodyBytes: responseBytes,
    );
  }

  Future<DartHttpClientStreamedResponse> _sendStreamWithoutInterceptors(
    DartHttpClientRequest request,
  ) async {
    final measured = upload_progress.sendWithUploadProgress(
      request,
      aborts: _uploadAborts,
      closed: _closed,
      withCredentials: browserUploadWithCredentials,
    );
    if (measured != null) return measured;
    final response = await _client.send(_httpRequestFrom(request));
    return DartHttpClientStreamedResponse(
      status: response.statusCode,
      contentType: response.headers['content-type'] ?? '',
      headers: response.headers,
      bodyStream: response.stream,
    );
  }

  http.BaseRequest _httpRequestFrom(DartHttpClientRequest request) {
    if (request.nativeBody != null) {
      throw UnsupportedError(
        'DartHttpClientTransport cannot consume a transport-specific native body.',
      );
    }
    final headers = _headersFor(request);
    final http.BaseRequest httpRequest;
    if (request.bodyStream case final bodyStream?) {
      httpRequest = _DartHttpStreamedRequest(
        request.method.wireName,
        request.uri,
        bodyStream: bodyStream,
        contentLength: request.bodyStreamLength,
        abortTrigger: request.abortTrigger,
      )..headers.addAll(headers);
    } else {
      final bufferedRequest = http.AbortableRequest(
        request.method.wireName,
        request.uri,
        abortTrigger: request.abortTrigger,
      )..headers.addAll(headers);

      if (request.bodyLease case final bodyLease?) {
        bufferedRequest.bodyBytes = bodyLease.takeDartBytes();
      } else if (request.bodyBytes case final bodyBytes?) {
        bufferedRequest.bodyBytes = bodyBytes;
      } else if (request.body case final body?) {
        bufferedRequest.body = body;
      }
      httpRequest = bufferedRequest;
    }
    httpRequest.followRedirects = request.redirectPolicy == DartHttpClientRedirectPolicy.follow;
    return httpRequest;
  }

  Map<String, String> _headersFor(DartHttpClientRequest request) {
    if (request.responseMode != DartHttpClientResponseMode.serverSentEvents) {
      return request.headers;
    }

    return <String, String>{
      for (final entry in request.headers.entries)
        if (!_sseHeaderNames.contains(entry.key.toLowerCase())) entry.key: entry.value,
      'accept': 'text/event-stream',
      'accept-encoding': 'identity',
    };
  }

  void close() {
    _closed = true;
    for (final abort in _uploadAborts.toList()) {
      abort();
    }
    _uploadAborts.clear();
    if (_ownsClient) {
      _client.close();
    }
  }
}

const _sseHeaderNames = <String>{'accept', 'accept-encoding'};

final class _DartHttpStreamedRequest extends http.BaseRequest with http.Abortable {
  _DartHttpStreamedRequest(
    super.method,
    super.url, {
    required this._bodyStream,
    int? contentLength,
    this.abortTrigger,
  }) {
    this.contentLength = contentLength;
  }

  final Stream<List<int>> _bodyStream;

  @override
  final Future<void>? abortTrigger;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_bodyStream);
  }
}
