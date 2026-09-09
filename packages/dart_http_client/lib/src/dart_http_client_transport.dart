import 'package:dart_http_core/dart_http_core.dart';
import 'package:http/http.dart' as http;

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
    List<DartHttpClientInterceptor> interceptors = const [],
    List<DartHttpClientStreamedInterceptor> streamedInterceptors = const [],
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _interceptors = List<DartHttpClientInterceptor>.unmodifiable(interceptors),
       _streamedInterceptors = List<DartHttpClientStreamedInterceptor>.unmodifiable(
         streamedInterceptors,
       );

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
    final streamed = await _client.send(_httpRequestFrom(request));
    final response = await http.Response.fromStream(streamed);
    return DartHttpClientResponse.ownedBytes(
      status: response.statusCode,
      contentType: response.headers['content-type'] ?? '',
      headers: response.headers,
      bodyBytes: response.bodyBytes,
    );
  }

  Future<DartHttpClientStreamedResponse> _sendStreamWithoutInterceptors(
    DartHttpClientRequest request,
  ) async {
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

/// Adds an `Authorization: Bearer <token>` header to generated client requests.
final class DartHttpBearerTokenInterceptor {
  const DartHttpBearerTokenInterceptor(this.token);

  final Future<String?> Function() token;

  Future<DartHttpClientResponse> call(
    DartHttpClientRequest request,
    DartHttpClientSend next,
  ) async {
    final resolvedToken = await token();
    if (resolvedToken == null || resolvedToken.isEmpty) {
      return next(request);
    }
    return next(
      request.copyWith(headers: {...request.headers, 'authorization': 'Bearer $resolvedToken'}),
    );
  }

  Future<DartHttpClientStreamedResponse> stream(
    DartHttpClientRequest request,
    DartHttpClientStreamedSend next,
  ) async {
    final resolvedToken = await token();
    if (resolvedToken == null || resolvedToken.isEmpty) {
      return next(request);
    }
    return next(
      request.copyWith(headers: {...request.headers, 'authorization': 'Bearer $resolvedToken'}),
    );
  }
}
