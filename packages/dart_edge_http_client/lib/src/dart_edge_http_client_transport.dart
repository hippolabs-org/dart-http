import 'package:dart_edge_core/dart_edge_core.dart';
import 'package:http/http.dart' as http;

typedef DartEdgeClientSend = Future<DartEdgeClientResponse> Function(DartEdgeClientRequest request);

typedef DartEdgeClientInterceptor = Future<DartEdgeClientResponse> Function(
  DartEdgeClientRequest request,
  DartEdgeClientSend next,
);

typedef DartEdgeClientStreamedSend = Future<DartEdgeClientStreamedResponse> Function(
  DartEdgeClientRequest request,
);

typedef DartEdgeClientStreamedInterceptor = Future<DartEdgeClientStreamedResponse> Function(
  DartEdgeClientRequest request,
  DartEdgeClientStreamedSend next,
);

/// Sends generated client requests through `package:http`.
final class DartEdgeHttpClientTransport implements DartEdgeClientTransport {
  DartEdgeHttpClientTransport({
    http.Client? client,
    List<DartEdgeClientInterceptor> interceptors = const [],
    List<DartEdgeClientStreamedInterceptor> streamedInterceptors = const [],
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _interceptors = List<DartEdgeClientInterceptor>.unmodifiable(interceptors),
       _streamedInterceptors = List<DartEdgeClientStreamedInterceptor>.unmodifiable(
         streamedInterceptors,
       );

  final http.Client _client;
  final bool _ownsClient;
  final List<DartEdgeClientInterceptor> _interceptors;
  final List<DartEdgeClientStreamedInterceptor> _streamedInterceptors;

  @override
  Future<DartEdgeClientResponse> send(DartEdgeClientRequest request) {
    DartEdgeClientSend next = _sendWithoutInterceptors;
    for (final interceptor in _interceptors.reversed) {
      final current = next;
      next = (request) => interceptor(request, current);
    }
    return next(request);
  }

  @override
  Future<DartEdgeClientStreamedResponse> sendStream(DartEdgeClientRequest request) {
    DartEdgeClientStreamedSend next = _sendStreamWithoutInterceptors;
    for (final interceptor in _streamedInterceptors.reversed) {
      final current = next;
      next = (request) => interceptor(request, current);
    }
    return next(request);
  }

  Future<DartEdgeClientResponse> _sendWithoutInterceptors(DartEdgeClientRequest request) async {
    final streamed = await _client.send(_httpRequestFrom(request));
    final response = await http.Response.fromStream(streamed);
    return DartEdgeClientResponse(
      status: response.statusCode,
      contentType: response.headers['content-type'] ?? '',
      headers: response.headers,
      bodyBytes: response.bodyBytes,
    );
  }

  Future<DartEdgeClientStreamedResponse> _sendStreamWithoutInterceptors(
    DartEdgeClientRequest request,
  ) async {
    final response = await _client.send(_httpRequestFrom(request));
    return DartEdgeClientStreamedResponse(
      status: response.statusCode,
      contentType: response.headers['content-type'] ?? '',
      headers: response.headers,
      bodyStream: response.stream,
    );
  }

  http.BaseRequest _httpRequestFrom(DartEdgeClientRequest request) {
    final http.BaseRequest httpRequest;
    if (request.bodyStream case final bodyStream?) {
      httpRequest = _DartEdgeHttpStreamedRequest(
        request.method.wireName,
        request.uri,
        bodyStream: bodyStream,
        contentLength: request.bodyStreamLength,
        abortTrigger: request.abortTrigger,
      )..headers.addAll(request.headers);
    } else {
      final bufferedRequest = http.AbortableRequest(
        request.method.wireName,
        request.uri,
        abortTrigger: request.abortTrigger,
      )..headers.addAll(request.headers);

      if (request.bodyBytes case final bodyBytes?) {
        bufferedRequest.bodyBytes = bodyBytes;
      } else if (request.body case final body?) {
        bufferedRequest.body = body;
      }
      httpRequest = bufferedRequest;
    }
    return httpRequest;
  }

  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }
}

final class _DartEdgeHttpStreamedRequest extends http.BaseRequest with http.Abortable {
  _DartEdgeHttpStreamedRequest(
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
final class DartEdgeBearerTokenInterceptor {
  const DartEdgeBearerTokenInterceptor(this.token);

  final Future<String?> Function() token;

  Future<DartEdgeClientResponse> call(
    DartEdgeClientRequest request,
    DartEdgeClientSend next,
  ) async {
    final resolvedToken = await token();
    if (resolvedToken == null || resolvedToken.isEmpty) {
      return next(request);
    }
    return next(
      request.copyWith(headers: {...request.headers, 'authorization': 'Bearer $resolvedToken'}),
    );
  }

  Future<DartEdgeClientStreamedResponse> stream(
    DartEdgeClientRequest request,
    DartEdgeClientStreamedSend next,
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
