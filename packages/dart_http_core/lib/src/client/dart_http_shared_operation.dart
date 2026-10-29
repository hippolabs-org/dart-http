import 'dart:typed_data';

import 'dart_http_client.dart';
import 'dart_http_client_operation.dart';
import 'dart_http_client_transport.dart';
import '../http/multipart_form_data.dart';

/// A reusable encoder and schema identity for a request value.
final class DartHttpClientValueCodec<T> {
  const DartHttpClientValueCodec({this.schemaId, this.encoder});

  final String? schemaId;
  final Object? Function(T value)? encoder;

  DartHttpClientRequestValue<T> bind(T value) =>
      DartHttpClientRequestValue<T>(schemaId: schemaId, value: value, encoder: encoder);
}

/// A reusable encoder, content type and schema identity for a request body.
final class DartHttpClientBodyCodec<T> {
  const DartHttpClientBodyCodec({required this.contentType, this.schemaId, this.encoder});

  final String contentType;
  final String? schemaId;
  final Object? Function(T value)? encoder;

  DartHttpClientRequestBody<T> bind(T value) => DartHttpClientRequestBody<T>(
    contentType: contentType,
    schemaId: schemaId,
    value: value,
    encoder: encoder,
  );
}

/// Immutable HTTP endpoint metadata and codecs, shared by every invocation.
///
/// Codecs and errors describe the endpoint; request values and lifecycle never
/// live here. Generic arguments follow [DartHttpClientInvocation].
final class DartHttpClientEndpoint<R, P, Q, H, B> {
  DartHttpClientEndpoint({
    required this.info,
    required this.success,
    List<DartHttpClientErrorSpec> errors = const [],
    this.params,
    this.query,
    this.headers,
    this.body,
  }) : errors = List<DartHttpClientErrorSpec>.unmodifiable(errors);

  final DartHttpClientOperationInfo info;
  final DartHttpClientResponseSpec<R> success;
  final List<DartHttpClientErrorSpec> errors;
  final DartHttpClientValueCodec<P>? params;
  final DartHttpClientValueCodec<Q>? query;
  final DartHttpClientValueCodec<H>? headers;
  final DartHttpClientBodyCodec<B>? body;

  /// Binds per-request values. Generated operation signatures enforce which
  /// values are required; a missing nonnullable value also fails its cast here.
  DartHttpClientInvocation<R, P, Q, H, B> bind({
    P? params,
    Q? query,
    H? headers,
    B? body,
    Future<void>? abortTrigger,
    Duration? timeout,
    void Function(DartHttpMultipartUploadProgress progress)? onUploadProgress,
  }) {
    final method = info.method;
    if (method == null || info.kind != DartHttpClientOperationKind.http) {
      throw StateError('An HTTP endpoint requires HTTP metadata and a method.');
    }
    return DartHttpClientInvocation<R, P, Q, H, B>(
      method: method,
      pathTemplate: info.pathTemplate,
      success: success,
      errors: errors,
      params: this.params?.bind(params as P),
      query: this.query?.bind(query as Q),
      headers: this.headers?.bind(headers as H),
      body: this.body?.bind(body as B),
      abortTrigger: abortTrigger,
      timeout: timeout,
      onMultipartUploadProgress: onUploadProgress,
    );
  }
}

/// Immutable metadata and request codecs for a realtime connection.
final class DartHttpClientConnectionEndpoint<P, Q, H> {
  const DartHttpClientConnectionEndpoint({
    required this.info,
    this.params,
    this.query,
    this.headers,
  });

  final DartHttpClientOperationInfo info;
  final DartHttpClientValueCodec<P>? params;
  final DartHttpClientValueCodec<Q>? query;
  final DartHttpClientValueCodec<H>? headers;

  DartHttpClientWebSocketInvocation<P, Q, H> webSocket({
    P? params,
    Q? query,
    H? headers,
    List<String> protocols = const [],
  }) {
    if (info.kind != DartHttpClientOperationKind.webSocket) {
      throw StateError('Expected WebSocket endpoint metadata.');
    }
    return DartHttpClientWebSocketInvocation<P, Q, H>(
      pathTemplate: info.pathTemplate,
      params: this.params?.bind(params as P),
      query: this.query?.bind(query as Q),
      headers: this.headers?.bind(headers as H),
      protocols: protocols,
    );
  }

  DartHttpClientWebTransportInvocation<P, Q, H> webTransport({P? params, Q? query, H? headers}) {
    if (info.kind != DartHttpClientOperationKind.webTransport) {
      throw StateError('Expected WebTransport endpoint metadata.');
    }
    return DartHttpClientWebTransportInvocation<P, Q, H>(
      pathTemplate: info.pathTemplate,
      params: this.params?.bind(params as P),
      query: this.query?.bind(query as Q),
      headers: this.headers?.bind(headers as H),
    );
  }
}

abstract base class _HttpOperation<R, P, Q, H, B> {
  const _HttpOperation({required this._client, required this._endpoint});

  final DartHttpClientBase _client;
  final DartHttpClientEndpoint<R, P, Q, H, B> _endpoint;

  DartHttpClientOperationInfo get info => _endpoint.info;

  Future<DartHttpClientResponseObject<R>> _send({
    P? params,
    Q? query,
    H? headers,
    B? body,
    Future<void>? abortTrigger,
    Duration? timeout,
    void Function(DartHttpMultipartUploadProgress progress)? onUploadProgress,
  }) => _client.invoke<R, P, Q, H, B>(
    _endpoint.bind(
      params: params,
      query: query,
      headers: headers,
      body: body,
      abortTrigger: abortTrigger,
      timeout: timeout,
      onUploadProgress: onUploadProgress,
    ),
  );

  Future<DartHttpClientStreamedResponseObject> _stream({
    P? params,
    Q? query,
    H? headers,
    B? body,
    Future<void>? abortTrigger,
    Duration? timeout,
  }) => _client.invokeStream<P, Q, H, B>(
    _endpoint.bind(
      params: params,
      query: query,
      headers: headers,
      body: body,
      abortTrigger: abortTrigger,
      timeout: timeout,
    ),
  );
}

/// Shared Json operation with no payload arguments.
final class DartHttpJsonOperation<R> extends _HttpOperation<R, Never, Never, Never, Never> {
  const DartHttpJsonOperation({required super.client, required super.endpoint});

  Future<DartHttpClientResponseObject<R>> call({Future<void>? abortTrigger, Duration? timeout}) =>
      _send(abortTrigger: abortTrigger, timeout: timeout);

  DartHttpClientRequestHandle<DartHttpClientResponseObject<R>> start({Duration? timeout}) =>
      startDartHttpClientRequest<DartHttpClientResponseObject<R>>(
        info: info,
        timeout: timeout,
        run: (abortTrigger) => call(abortTrigger: abortTrigger, timeout: timeout),
      );
}

/// Shared Json operation with body arguments.
final class DartHttpJsonBodyOperation<B, R> extends _HttpOperation<R, Never, Never, Never, B> {
  const DartHttpJsonBodyOperation({required super.client, required super.endpoint});

  Future<DartHttpClientResponseObject<R>> call({
    required B body,
    Future<void>? abortTrigger,
    Duration? timeout,
  }) => _send(body: body, abortTrigger: abortTrigger, timeout: timeout);

  DartHttpClientRequestHandle<DartHttpClientResponseObject<R>> start({
    required B body,
    Duration? timeout,
  }) => startDartHttpClientRequest<DartHttpClientResponseObject<R>>(
    info: info,
    timeout: timeout,
    run: (abortTrigger) => call(body: body, abortTrigger: abortTrigger, timeout: timeout),
  );
}

/// Shared Json operation with query arguments.
final class DartHttpJsonQueryOperation<Q, R> extends _HttpOperation<R, Never, Q?, Never, Never> {
  const DartHttpJsonQueryOperation({required super.client, required super.endpoint});

  Future<DartHttpClientResponseObject<R>> call({
    Q? query,
    Future<void>? abortTrigger,
    Duration? timeout,
  }) => _send(query: query, abortTrigger: abortTrigger, timeout: timeout);

  DartHttpClientRequestHandle<DartHttpClientResponseObject<R>> start({
    Q? query,
    Duration? timeout,
  }) => startDartHttpClientRequest<DartHttpClientResponseObject<R>>(
    info: info,
    timeout: timeout,
    run: (abortTrigger) => call(query: query, abortTrigger: abortTrigger, timeout: timeout),
  );
}

/// Shared MultipartJson operation with body arguments.
final class DartHttpMultipartJsonBodyOperation<B, R>
    extends _HttpOperation<R, Never, Never, Never, B> {
  const DartHttpMultipartJsonBodyOperation({required super.client, required super.endpoint});

  Future<DartHttpClientResponseObject<R>> call({
    required B body,
    Future<void>? abortTrigger,
    Duration? timeout,
    void Function(DartHttpMultipartUploadProgress progress)? onUploadProgress,
  }) => _send(
    body: body,
    abortTrigger: abortTrigger,
    timeout: timeout,
    onUploadProgress: onUploadProgress,
  );

  DartHttpClientRequestHandle<DartHttpClientResponseObject<R>> start({
    required B body,
    Duration? timeout,
    void Function(DartHttpMultipartUploadProgress progress)? onUploadProgress,
  }) => startDartHttpClientRequest<DartHttpClientResponseObject<R>>(
    info: info,
    timeout: timeout,
    run: (abortTrigger) => call(
      body: body,
      abortTrigger: abortTrigger,
      timeout: timeout,
      onUploadProgress: onUploadProgress,
    ),
  );
}

/// Shared Binary operation with no payload arguments.
final class DartHttpBinaryOperation extends _HttpOperation<Uint8List, Never, Never, Never, Never> {
  const DartHttpBinaryOperation({required super.client, required super.endpoint});

  Future<DartHttpClientResponseObject<Uint8List>> call({
    Future<void>? abortTrigger,
    Duration? timeout,
  }) => _send(abortTrigger: abortTrigger, timeout: timeout);

  DartHttpClientRequestHandle<DartHttpClientResponseObject<Uint8List>> start({Duration? timeout}) =>
      startDartHttpClientRequest<DartHttpClientResponseObject<Uint8List>>(
        info: info,
        timeout: timeout,
        run: (abortTrigger) => call(abortTrigger: abortTrigger, timeout: timeout),
      );

  Future<DartHttpClientStreamedResponseObject> stream({
    Future<void>? abortTrigger,
    Duration? timeout,
  }) => _stream(abortTrigger: abortTrigger, timeout: timeout);
}

/// Shared Binary operation with body arguments.
final class DartHttpBinaryBodyOperation<B>
    extends _HttpOperation<Uint8List, Never, Never, Never, B> {
  const DartHttpBinaryBodyOperation({required super.client, required super.endpoint});

  Future<DartHttpClientResponseObject<Uint8List>> call({
    required B body,
    Future<void>? abortTrigger,
    Duration? timeout,
  }) => _send(body: body, abortTrigger: abortTrigger, timeout: timeout);

  DartHttpClientRequestHandle<DartHttpClientResponseObject<Uint8List>> start({
    required B body,
    Duration? timeout,
  }) => startDartHttpClientRequest<DartHttpClientResponseObject<Uint8List>>(
    info: info,
    timeout: timeout,
    run: (abortTrigger) => call(body: body, abortTrigger: abortTrigger, timeout: timeout),
  );

  Future<DartHttpClientStreamedResponseObject> stream({
    required B body,
    Future<void>? abortTrigger,
    Duration? timeout,
  }) => _stream(body: body, abortTrigger: abortTrigger, timeout: timeout);
}

/// Shared Binary operation with query arguments.
final class DartHttpBinaryQueryOperation<Q>
    extends _HttpOperation<Uint8List, Never, Q?, Never, Never> {
  const DartHttpBinaryQueryOperation({required super.client, required super.endpoint});

  Future<DartHttpClientResponseObject<Uint8List>> call({
    Q? query,
    Future<void>? abortTrigger,
    Duration? timeout,
  }) => _send(query: query, abortTrigger: abortTrigger, timeout: timeout);

  DartHttpClientRequestHandle<DartHttpClientResponseObject<Uint8List>> start({
    Q? query,
    Duration? timeout,
  }) => startDartHttpClientRequest<DartHttpClientResponseObject<Uint8List>>(
    info: info,
    timeout: timeout,
    run: (abortTrigger) => call(query: query, abortTrigger: abortTrigger, timeout: timeout),
  );

  Future<DartHttpClientStreamedResponseObject> stream({
    Q? query,
    Future<void>? abortTrigger,
    Duration? timeout,
  }) => _stream(query: query, abortTrigger: abortTrigger, timeout: timeout);
}

/// Shared Sse operation with no payload arguments.
final class DartHttpSseOperation extends _HttpOperation<Object?, Never, Never, Never, Never> {
  const DartHttpSseOperation({required super.client, required super.endpoint});

  Future<DartHttpClientStreamedResponseObject> call({
    Future<void>? abortTrigger,
    Duration? timeout,
  }) => _stream(abortTrigger: abortTrigger, timeout: timeout);

  DartHttpClientRequestHandle<DartHttpClientStreamedResponseObject> start({Duration? timeout}) =>
      startDartHttpClientRequest<DartHttpClientStreamedResponseObject>(
        info: info,
        timeout: timeout,
        run: (abortTrigger) => call(abortTrigger: abortTrigger, timeout: timeout),
      );
}

/// Shared Sse operation with body arguments.
final class DartHttpSseBodyOperation<B> extends _HttpOperation<Object?, Never, Never, Never, B> {
  const DartHttpSseBodyOperation({required super.client, required super.endpoint});

  Future<DartHttpClientStreamedResponseObject> call({
    required B body,
    Future<void>? abortTrigger,
    Duration? timeout,
  }) => _stream(body: body, abortTrigger: abortTrigger, timeout: timeout);

  DartHttpClientRequestHandle<DartHttpClientStreamedResponseObject> start({
    required B body,
    Duration? timeout,
  }) => startDartHttpClientRequest<DartHttpClientStreamedResponseObject>(
    info: info,
    timeout: timeout,
    run: (abortTrigger) => call(body: body, abortTrigger: abortTrigger, timeout: timeout),
  );
}

/// Shared Sse operation with query arguments.
final class DartHttpSseQueryOperation<Q> extends _HttpOperation<Object?, Never, Q?, Never, Never> {
  const DartHttpSseQueryOperation({required super.client, required super.endpoint});

  Future<DartHttpClientStreamedResponseObject> call({
    Q? query,
    Future<void>? abortTrigger,
    Duration? timeout,
  }) => _stream(query: query, abortTrigger: abortTrigger, timeout: timeout);

  DartHttpClientRequestHandle<DartHttpClientStreamedResponseObject> start({
    Q? query,
    Duration? timeout,
  }) => startDartHttpClientRequest<DartHttpClientStreamedResponseObject>(
    info: info,
    timeout: timeout,
    run: (abortTrigger) => call(query: query, abortTrigger: abortTrigger, timeout: timeout),
  );
}

/// Shared WebSocket operation with an optional typed query.
final class DartHttpWebSocketQueryOperation<Q> {
  const DartHttpWebSocketQueryOperation({required this._client, required this._endpoint});

  final DartHttpClientBase _client;
  final DartHttpClientConnectionEndpoint<Never, Q?, Never> _endpoint;
  DartHttpClientOperationInfo get info => _endpoint.info;

  Future<DartHttpClientWebSocket> connect({Q? query, List<String> protocols = const []}) => _client
      .connectWebSocket<Never, Q?, Never>(_endpoint.webSocket(query: query, protocols: protocols));
}

/// Shared WebTransport operation without payload arguments.
final class DartHttpWebTransportOperation {
  const DartHttpWebTransportOperation({required this._client, required this._endpoint});

  final DartHttpClientBase _client;
  final DartHttpClientConnectionEndpoint<Never, Never, Never> _endpoint;
  DartHttpClientOperationInfo get info => _endpoint.info;

  Future<DartHttpClientWebTransportSession> connect() =>
      _client.connectWebTransport<Never, Never, Never>(_endpoint.webTransport());
}
