import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:dart_http_core/dart_http_core.dart';
import 'package:native_exchange/native_exchange_ffi.dart' show NativeByteLease;
import 'package:json_schema/json_schema.dart';

import '../native/dart_http_native.dart';
import '../native/native_transport_web_socket.dart';
import '../native/native_transport_web_transport.dart';
import 'compiled_route.dart';
import 'compiled_route_table.dart';
import 'dart_http_codec.dart';
import 'dart_http_server_instance.dart';
import 'json_schema_route_id.dart';
import 'native_binary_stream_response.dart';
import 'open_api_document.dart';
import 'request_decoder.dart';
import 'response_writer.dart';
import 'rust_middleware.dart';
import 'transport_request.dart';

const _transportEventRequestReady = 1;
const _transportEventWebSocketOpened = 2;
const _transportEventWebSocketMessageReady = 3;
const _transportEventWebSocketClosed = 4;
const _transportEventWebTransportOpened = 5;
const _transportEventWebTransportDatagramReady = 6;
const _transportEventWebTransportClosed = 7;
const _transportEventWebTransportStreamReady = 8;
const _transportEventWebTransportPersistentStreamOpened = 9;
const _transportEventWebTransportStreamChunkReady = 10;
const _transportEventWebTransportStreamFinished = 11;
const _transportEventWebTransportOperationReady = 12;

/// Main application object for a Dart HTTP server.
///
/// A [DartHttp] instance owns the route registry, service factory, optional
/// JSON Schema registry, and native middleware configuration for one server.
class DartHttp<TServices> extends Router<TServices> {
  /// Creates a new application instance.
  DartHttp({
    this.services,
    OpenApiDocument? openApiDocument,
    List<RustMiddleware>? middlewares,
    List<HttpRequestObserver<TServices>>? requestObservers,
    DartHttpCodecRegistry codecs = DartHttpCodecRegistry.empty,
  }) : middlewares = List.unmodifiable(middlewares ?? const <RustMiddleware>[]),
       requestObservers = List.unmodifiable(requestObservers ?? <HttpRequestObserver<TServices>>[]),
       openApiDocument = openApiDocument ?? OpenApiDocument(),
       _codecRegistry = codecs;

  /// Factory used to build request-scoped services.
  final TServices Function()? services;

  /// Native middleware configuration applied before requests reach Dart.
  final List<RustMiddleware> middlewares;

  /// Dart-side request observers applied around every Dart HTTP route.
  final List<HttpRequestObserver<TServices>> requestObservers;

  /// Application-level OpenAPI metadata attached to the app.
  final OpenApiDocument openApiDocument;
  JsonSchemaRegistry? _schemaRegistry;
  DartHttpCodecRegistry _codecRegistry;
  _RustTransportSession? _session;
  final Map<int, RequestContext<TServices>> _pendingWebSocketContexts =
      <int, RequestContext<TServices>>{};
  final Map<int, _ActiveWebSocketSession> _activeWebSocketSessions =
      <int, _ActiveWebSocketSession>{};
  final Map<int, RequestContext<TServices>> _pendingWebTransportContexts =
      <int, RequestContext<TServices>>{};
  final Map<int, _ActiveWebTransportSession> _activeWebTransportSessions =
      <int, _ActiveWebTransportSession>{};
  final Map<int, Completer<NativeWebTransportOperation>> _pendingWebTransportOperations =
      <int, Completer<NativeWebTransportOperation>>{};
  final Map<int, NativeWebTransportOperation> _earlyWebTransportOperations =
      <int, NativeWebTransportOperation>{};

  /// Installed JSON Schema registry used for validation and manifests.
  JsonSchemaRegistry? get schemaRegistry => _schemaRegistry;

  /// Installed runtime codec registry used for request decoding.
  DartHttpCodecRegistry get codecRegistry => _codecRegistry;

  /// Installs the JSON Schema registry for this app.
  void installSchemaRegistry(JsonSchemaRegistry registry) {
    _schemaRegistry = registry;
  }

  /// Installs the runtime codec registry for this app.
  void installCodecRegistry(DartHttpCodecRegistry registry) {
    _codecRegistry = registry;
  }

  /// Builds the current OpenAPI JSON document for the registered routes.
  Map<String, Object?> buildOpenApiDocumentJson() {
    final compiledRoutes = _compileRoutes();
    return openApiDocument.toJson(
      routes: [
        ...compiledRoutes.routes.where((route) => route.options.exposure.openApi),
        ...compiledRoutes.nativeRoutes.where((route) => route.options.exposure.openApi),
      ],
      schemaRegistry: _schemaRegistry,
    );
  }

  /// Starts the native HTTP server and begins handling requests.
  ///
  /// [host] controls the bind address used by the native listener. Keep the
  /// default loopback host for local-only development, or pass `0.0.0.0` /
  /// `::` when deploying behind a reverse proxy or in a container.
  ///
  /// When [port] is `0`, the runtime binds an ephemeral free port and returns
  /// the chosen port via the resulting [DartHttpServer].
  Future<DartHttpServer> listen({
    String host = '127.0.0.1',
    required int port,
    int workers = 1,
  }) async {
    final normalizedHost = host.trim();
    if (normalizedHost.isEmpty) {
      throw ArgumentError.value(host, 'host', 'Must not be empty.');
    }

    RangeError.checkNotNegative(workers, 'workers');
    if (workers == 0) {
      throw RangeError.value(workers, 'workers', 'Must be greater than zero.');
    }

    final existingSession = _session;
    if (existingSession != null) {
      throw StateError(
        'DartHttp is already listening on ${existingSession.host}:${existingSession.port}.',
      );
    }

    final compiledRoutes = _compileRoutes();

    final session = await _RustTransportSession.start(
      host: normalizedHost,
      requestedPort: port,
      workers: workers,
      routesJson: compiledRoutes.nativeManifestJson(schemaRegistry: _schemaRegistry),
      middlewaresJson: _middlewaresJson(middlewares),
      onTransportEvent: (eventKind, eventId) async {
        await _handleTransportEvent(eventKind, eventId, compiledRoutes);
      },
    );
    _session = session;

    return DartHttpServer(
      host: session.host,
      port: session.port,
      onClose: () async {
        final currentSession = _session;
        if (currentSession == null) {
          return;
        }
        _session = null;
        await currentSession.close();
        _pendingWebSocketContexts.clear();
        for (final session in _activeWebSocketSessions.values.toList()) {
          await session.messages.close();
        }
        _activeWebSocketSessions.clear();
        _pendingWebTransportContexts.clear();
        for (final session in _activeWebTransportSessions.values.toList()) {
          unawaited(session.close());
        }
        _activeWebTransportSessions.clear();
        for (final completer in _pendingWebTransportOperations.values) {
          completer.completeError(
            StateError('WebTransport server closed during native operation.'),
          );
        }
        _pendingWebTransportOperations.clear();
        _earlyWebTransportOperations.clear();
      },
    );
  }

  Future<void> _handleTransportEvent(
    int eventKind,
    int eventId,
    CompiledRouteTable<TServices> compiledRoutes,
  ) async {
    switch (eventKind) {
      case _transportEventRequestReady:
        await _handleTransportRequest(eventId, compiledRoutes);
        return;
      case _transportEventWebSocketOpened:
        await _handleWebSocketOpened(eventId, compiledRoutes);
        return;
      case _transportEventWebSocketMessageReady:
        _drainWebSocketMessages(eventId);
        return;
      case _transportEventWebSocketClosed:
        await _handleWebSocketClosed(eventId);
        return;
      case _transportEventWebTransportOpened:
        await _handleWebTransportOpened(eventId, compiledRoutes);
        return;
      case _transportEventWebTransportDatagramReady:
        _drainWebTransportDatagrams(eventId);
        return;
      case _transportEventWebTransportClosed:
        await _handleWebTransportClosed(eventId);
        return;
      case _transportEventWebTransportStreamReady:
        _drainWebTransportStreams(eventId);
        return;
      case _transportEventWebTransportPersistentStreamOpened:
        _handleWebTransportPersistentStreamOpened(eventId);
        return;
      case _transportEventWebTransportStreamChunkReady:
        _drainWebTransportStreamChunks(eventId);
        return;
      case _transportEventWebTransportStreamFinished:
        await _handleWebTransportStreamFinished(eventId);
        return;
      case _transportEventWebTransportOperationReady:
        _handleWebTransportOperationReady(eventId);
        return;
    }
  }

  Future<void> _handleTransportRequest(
    int requestId,
    CompiledRouteTable<TServices> compiledRoutes,
  ) async {
    final requestLease = DartHttpNative.takeRequest(requestId);
    if (requestLease == null) {
      return;
    }
    final request = requestLease.request;
    final operationId = _transportOperationId(request, compiledRoutes);

    try {
      switch (request.requestKind) {
        case TransportRequestKind.http:
          await _handleHttpRequest(requestId, requestLease, compiledRoutes);
          return;
        case TransportRequestKind.webSocket:
          await _handleWebSocketHandshake(requestId, requestLease, compiledRoutes);
          return;
        case TransportRequestKind.webTransport:
          await _handleWebTransportHandshake(requestId, requestLease, compiledRoutes);
          return;
      }
    } catch (error, stackTrace) {
      stderr.writeln(
        'dart_http_server_runtime request handling failed for '
        '$operationId: $error',
      );
      stderr.writeln(stackTrace);
      _respondServerError(requestId);
    } finally {
      requestLease.dispose();
    }
  }

  Future<void> _handleHttpRequest(
    int requestId,
    NativeTransportRequestLease requestLease,
    CompiledRouteTable<TServices> compiledRoutes,
  ) async {
    final request = requestLease.request;
    final compiledRoute = compiledRoutes.routesById[request.routeId];
    if (compiledRoute == null) {
      _respondServerError(requestId);
      return;
    }

    final input = await decodeRequestInput(
      request,
      codecs: _codecRegistry,
      nativeRequest: requestLease.nativeRequest,
      paramsSchemaId: jsonSchemaRouteId(compiledRoute.options.params),
      querySchemaId: jsonSchemaRouteId(compiledRoute.options.query),
      headersSchemaId: jsonSchemaRouteId(compiledRoute.options.headers),
      paramsDecoder: compiledRoute.options.paramsDecoder,
      queryDecoder: compiledRoute.options.queryDecoder,
      body: compiledRoute.options.body,
    );
    final ctx = RequestContext<TServices>(services: _createServices(), req: input);
    await _observeHttpRequest(ctx, compiledRoute, () async {
      for (final guard in compiledRoute.guards) {
        final decisionResult = guard.authorize(ctx);
        final decision = decisionResult is Future<GuardResult>
            ? await decisionResult
            : decisionResult;
        if (!decision.isAllowed) {
          final response = encodeResponse(
            spec: compiledRoute.options.responses.success,
            body: decision.response,
            response: ctx.res,
          );
          DartHttpNative.tryRespond(
            requestId,
            status: response.status,
            contentType: response.contentType,
            body: response.bodyBytes,
            headers: response.headers,
          );
          return HttpRequestObservationResult(
            statusCode: response.status,
            responseBodySize: response.bodyBytes.length,
          );
        }
      }

      final bodyResult = compiledRoute.route.handle(ctx);
      final body = bodyResult is Future ? await bodyResult : bodyResult;
      final nativeBinaryStreamResponse = _resolveNativeBinaryStreamResponse(body, ctx.res);
      if (nativeBinaryStreamResponse != null) {
        _streamNativeBinaryResponse(requestId, nativeBinaryStreamResponse);
        return HttpRequestObservationResult(
          statusCode: nativeBinaryStreamResponse.status,
          responseBodySize: nativeBinaryStreamResponse.contentLength,
        );
      }
      final binaryStreamResponse = _resolveBinaryStreamResponse(body, ctx.res);
      if (binaryStreamResponse != null) {
        await _streamBinaryResponse(requestId, binaryStreamResponse);
        return HttpRequestObservationResult(
          statusCode: binaryStreamResponse.status,
          responseBodySize: binaryStreamResponse.contentLength,
        );
      }
      final sseResponse = _resolveSseResponse(body, ctx.res);
      if (sseResponse != null) {
        await _streamSseResponse(requestId, sseResponse);
        return HttpRequestObservationResult(
          statusCode: compiledRoute.options.responses.success.status,
        );
      }

      final response = encodeResponse(
        spec: compiledRoute.options.responses.success,
        body: body,
        response: ctx.res,
      );

      DartHttpNative.tryRespond(
        requestId,
        status: response.status,
        contentType: response.contentType,
        body: response.bodyBytes,
        headers: response.headers,
      );
      return HttpRequestObservationResult(
        statusCode: response.status,
        responseBodySize: response.bodyBytes.length,
      );
    });
  }

  Future<HttpRequestObservationResult> _observeHttpRequest(
    RequestContext<TServices> ctx,
    CompiledRoute<TServices> route,
    Future<HttpRequestObservationResult> Function() next,
  ) {
    final request = HttpRequestObservation(
      method: route.method,
      route: route.path,
      operationId: route.options.operationId!,
      successStatusCode: route.options.responses.success.status,
    );
    Future<HttpRequestObservationResult> Function() wrapped = next;
    for (final observer in requestObservers.reversed) {
      final inner = wrapped;
      wrapped = () async {
        return observer.observe(context: ctx, request: request, next: inner);
      };
    }
    return wrapped();
  }

  Future<void> _handleWebSocketHandshake(
    int requestId,
    NativeTransportRequestLease requestLease,
    CompiledRouteTable<TServices> compiledRoutes,
  ) async {
    final request = requestLease.request;
    final compiledRoute = compiledRoutes.webSocketRoutesById[request.routeId];
    if (compiledRoute == null) {
      _respondServerError(requestId);
      return;
    }

    final input = await decodeRequestInput(
      request,
      codecs: _codecRegistry,
      nativeRequest: null,
      paramsSchemaId: jsonSchemaRouteId(compiledRoute.options.params),
      querySchemaId: jsonSchemaRouteId(compiledRoute.options.query),
      headersSchemaId: null,
      paramsDecoder: compiledRoute.options.paramsDecoder,
      queryDecoder: compiledRoute.options.queryDecoder,
      body: null,
    );
    final ctx = RequestContext<TServices>(services: _createServices(), req: input);
    for (final guard in compiledRoute.guards) {
      final decision = await Future.sync(() => guard.authorize(ctx));
      if (!decision.isAllowed) {
        final response = encodeResponse(
          spec: ResponseSpec.text(),
          body: decision.response,
          response: ctx.res,
        );
        DartHttpNative.tryRespond(
          requestId,
          status: response.status,
          contentType: response.contentType,
          body: response.bodyBytes,
          headers: response.headers,
        );
        return;
      }
    }

    _pendingWebSocketContexts[requestId] = ctx;
    final accepted = DartHttpNative.acceptWebSocket(requestId, headers: ctx.res.headers);
    if (!accepted) {
      _pendingWebSocketContexts.remove(requestId);
      _respondServerError(requestId);
    }
  }

  Future<void> _handleWebSocketOpened(
    int sessionId,
    CompiledRouteTable<TServices> compiledRoutes,
  ) async {
    final connection = DartHttpNative.takeWebSocketConnection(sessionId);
    if (connection == null) {
      return;
    }

    final compiledRoute = compiledRoutes.webSocketRoutesById[connection.routeId];
    if (compiledRoute == null) {
      DartHttpNative.webSocketClose(
        sessionId,
        reason: 'No Dart WebSocket route registered for ${connection.routeId}.',
      );
      return;
    }

    final requestContext =
        _pendingWebSocketContexts.remove(connection.requestId) ??
        RequestContext<TServices>(
          services: _createServices(),
          req: RequestInput(
            params: Map<String, String>.unmodifiable(connection.pathParams),
            query: Map<String, String>.unmodifiable(connection.query),
            headers: Map<String, String>.unmodifiable(connection.headers),
          ),
        );

    final activeSession = _ActiveWebSocketSession(StreamController<WebSocketMessage>());
    _activeWebSocketSessions[sessionId] = activeSession;

    final socket = WebSocketContext<TServices>.fromRequest(
      request: requestContext,
      messages: IncomingWebSocketMessages(activeSession.messages.stream),
      sendText: (value) => _sendWebSocketText(sessionId, value),
      sendBinary: (value) => _sendWebSocketBinary(sessionId, value),
      sendBinaryLease: (lease) => _sendWebSocketBinaryLease(sessionId, lease),
      sendJson: (value) => _sendWebSocketJson(sessionId, value),
      close: ([code, reason]) async {
        DartHttpNative.webSocketClose(sessionId, code: code, reason: reason);
      },
    );

    activeSession.task = Future.sync(() => compiledRoute.route.onConnect(socket))
        .catchError((Object error, StackTrace stackTrace) {
          stderr.writeln(
            'dart_http_server_runtime websocket handling failed for '
            '${compiledRoute.options.operationId}: $error',
          );
          stderr.writeln(stackTrace);
        })
        .whenComplete(() async {
          final session = _activeWebSocketSessions.remove(sessionId);
          await session?.messages.close();
          session?.closeLeases();
          DartHttpNative.webSocketClose(sessionId);
        });

    _drainWebSocketMessages(sessionId);
  }

  void _drainWebSocketMessages(int sessionId) {
    final session = _activeWebSocketSessions[sessionId];
    if (session == null || session.messages.isClosed) {
      return;
    }

    while (true) {
      final message = DartHttpNative.takeWebSocketMessage(sessionId);
      if (message == null) {
        return;
      }
      if (message.bodyLease case final lease?) {
        session.track(lease);
      }
      session.messages.add(_decodeWebSocketMessage(message));
    }
  }

  Future<void> _handleWebSocketClosed(int sessionId) async {
    try {
      // Drain frames posted immediately before the terminal notification
      // before exposing done to the route handler.
      _drainWebSocketMessages(sessionId);
      final session = _activeWebSocketSessions[sessionId];
      await session?.messages.close();
    } finally {
      DartHttpNative.releaseWebSocketSession(sessionId);
    }
  }

  Future<void> _handleWebTransportHandshake(
    int requestId,
    NativeTransportRequestLease requestLease,
    CompiledRouteTable<TServices> compiledRoutes,
  ) async {
    final request = requestLease.request;
    final compiledRoute = compiledRoutes.webTransportRoutesById[request.routeId];
    if (compiledRoute == null) {
      _respondServerError(requestId);
      return;
    }

    final input = await decodeRequestInput(
      request,
      codecs: _codecRegistry,
      nativeRequest: null,
      paramsSchemaId: null,
      querySchemaId: null,
      headersSchemaId: null,
      body: null,
    );
    final ctx = RequestContext<TServices>(services: _createServices(), req: input);
    for (final guard in compiledRoute.guards) {
      final decision = await Future.sync(() => guard.authorize(ctx));
      if (!decision.isAllowed) {
        final response = encodeResponse(
          spec: ResponseSpec.text(),
          body: decision.response,
          response: ctx.res,
        );
        DartHttpNative.tryRespond(
          requestId,
          status: response.status,
          contentType: response.contentType,
          body: response.bodyBytes,
          headers: response.headers,
        );
        return;
      }
    }

    _pendingWebTransportContexts[requestId] = ctx;
    final accepted = DartHttpNative.acceptWebTransport(requestId, headers: ctx.res.headers);
    if (!accepted) {
      _pendingWebTransportContexts.remove(requestId);
      _respondServerError(requestId);
    }
  }

  Future<void> _handleWebTransportOpened(
    int sessionId,
    CompiledRouteTable<TServices> compiledRoutes,
  ) async {
    final connection = DartHttpNative.takeWebTransportConnection(sessionId);
    if (connection == null) {
      return;
    }

    final compiledRoute = compiledRoutes.webTransportRoutesById[connection.routeId];
    if (compiledRoute == null) {
      DartHttpNative.webTransportClose(
        sessionId,
        reason: 'No Dart WebTransport route registered for ${connection.routeId}.',
      );
      return;
    }

    final requestContext =
        _pendingWebTransportContexts.remove(connection.requestId) ??
        RequestContext<TServices>(
          services: _createServices(),
          req: RequestInput(
            params: Map<String, String>.unmodifiable(connection.pathParams),
            query: Map<String, String>.unmodifiable(connection.query),
            headers: Map<String, String>.unmodifiable(connection.headers),
          ),
        );

    final activeSession = _ActiveWebTransportSession(
      sessionId,
      StreamController<BinaryPayloadLease>(),
      StreamController<BinaryPayloadLease>(),
      StreamController<WebTransportReceiveStream>(),
      StreamController<WebTransportBidirectionalStream>(),
    );
    _activeWebTransportSessions[sessionId] = activeSession;

    final transport = WebTransportContext<TServices>.fromRequest(
      request: requestContext,
      datagrams: IncomingWebTransportDatagrams.leased(activeSession.datagrams.stream),
      streams: IncomingWebTransportStreams.leased(activeSession.streams.stream),
      incomingStreams: IncomingWebTransportReceiveStreams(
        unidirectional: activeSession.unidirectional.stream,
        bidirectional: activeSession.bidirectional.stream,
      ),
      sendDatagram: (value) => _sendWebTransportDatagram(sessionId, value),
      sendDatagramLease: (lease) => _sendWebTransportDatagramLease(sessionId, lease),
      sendStream: (value) => _sendWebTransportStream(sessionId, value),
      sendStreamLease: (lease) => _sendWebTransportStreamLease(sessionId, lease),
      openUnidirectionalStream: () => _openWebTransportUnidirectionalStream(activeSession),
      openBidirectionalStream: () => _openWebTransportBidirectionalStream(activeSession),
      close: ([code, reason]) async {
        DartHttpNative.webTransportClose(sessionId, code: code, reason: reason);
      },
    );

    activeSession.task = Future.sync(() => compiledRoute.route.onConnect(transport))
        .catchError((Object error, StackTrace stackTrace) {
          stderr.writeln(
            'dart_http_server_runtime webtransport handling failed '
            'for ${compiledRoute.options.operationId}: $error',
          );
          stderr.writeln(stackTrace);
        })
        .whenComplete(() async {
          final session = _activeWebTransportSessions.remove(sessionId);
          await session?.close();
          session?.closeLeases();
          DartHttpNative.webTransportClose(sessionId);
        });

    _drainWebTransportDatagrams(sessionId);
    _drainWebTransportStreams(sessionId);
  }

  void _drainWebTransportDatagrams(int sessionId) {
    final session = _activeWebTransportSessions[sessionId];
    if (session == null || session.datagrams.isClosed) {
      return;
    }

    while (true) {
      final datagram = DartHttpNative.takeWebTransportDatagram(sessionId);
      if (datagram == null) {
        return;
      }
      session.track(datagram.bodyLease);
      session.datagrams.add(datagram.bodyLease);
    }
  }

  Future<void> _handleWebTransportClosed(int sessionId) async {
    final session = _activeWebTransportSessions[sessionId];
    await session?.datagrams.close();
    await session?.streams.close();
    await session?.unidirectional.close();
    await session?.bidirectional.close();
    if (session != null) {
      for (final stream in session.persistentStreams.values) {
        await stream.chunks.close();
      }
    }
  }

  void _drainWebTransportStreams(int sessionId) {
    final session = _activeWebTransportSessions[sessionId];
    if (session == null || session.streams.isClosed) {
      return;
    }

    while (true) {
      final stream = DartHttpNative.takeWebTransportStream(sessionId);
      if (stream == null) {
        return;
      }
      session.track(stream.bodyLease);
      session.streams.add(stream.bodyLease);
    }
  }

  void _handleWebTransportPersistentStreamOpened(int streamId) {
    final info = DartHttpNative.takeWebTransportStreamInfo(streamId);
    if (info == null) return;
    final session = _activeWebTransportSessions[info.sessionId];
    if (session == null) return;
    final stream = _registerWebTransportPersistentStream(session, info);
    switch (info.kind) {
      case 1:
        session.unidirectional.add(stream.receive);
      case 2:
        session.bidirectional.add(
          WebTransportBidirectionalStream(receive: stream.receive, send: stream.send),
        );
      default:
        unawaited(stream.chunks.close());
        return;
    }
    _drainWebTransportStreamChunks(streamId);
  }

  void _drainWebTransportStreamChunks(int streamId) {
    final stream = _activeWebTransportStream(streamId);
    if (stream == null || stream.chunks.isClosed) return;
    while (true) {
      final chunk = DartHttpNative.takeWebTransportStreamChunk(streamId);
      if (chunk == null) return;
      stream.session.track(chunk.bodyLease);
      stream.chunks.add(chunk.bodyLease);
    }
  }

  Future<void> _handleWebTransportStreamFinished(int streamId) async {
    final stream = _activeWebTransportStream(streamId);
    final terminal = DartHttpNative.takeWebTransportStreamTerminal(streamId);
    if (stream == null || terminal == null) return;
    _drainWebTransportStreamChunks(streamId);
    if (terminal.error.isNotEmpty && terminal.error != 'receive stopped locally') {
      stream.chunks.addError(StateError('WebTransport stream $streamId ended: ${terminal.error}'));
    }
    await stream.chunks.close();
  }

  void _handleWebTransportOperationReady(int operationId) {
    final operation = DartHttpNative.takeWebTransportOperation(operationId);
    if (operation == null) return;
    final completer = _pendingWebTransportOperations.remove(operationId);
    if (completer != null) {
      completer.complete(operation);
    } else {
      _earlyWebTransportOperations[operationId] = operation;
    }
  }

  Future<NativeWebTransportOperation> _waitForWebTransportOperation(
    int operationId,
    String action,
  ) async {
    if (operationId == 0) {
      throw StateError('Failed to submit WebTransport $action.');
    }
    final early = _earlyWebTransportOperations.remove(operationId);
    final operation =
        early ??
        await (_pendingWebTransportOperations[operationId] =
                Completer<NativeWebTransportOperation>())
            .future;
    if (!operation.succeeded) {
      throw StateError(
        'WebTransport $action failed${operation.error.isEmpty ? '.' : ': ${operation.error}'}',
      );
    }
    return operation;
  }

  Future<WebTransportSendStream> _openWebTransportUnidirectionalStream(
    _ActiveWebTransportSession session,
  ) async {
    final operation = await _waitForWebTransportOperation(
      DartHttpNative.webTransportOpenUnidirectionalStream(session.sessionId),
      'unidirectional stream open',
    );
    final stream = _registerWebTransportPersistentStreamFromOperation(session, operation);
    return stream.send;
  }

  Future<WebTransportBidirectionalStream> _openWebTransportBidirectionalStream(
    _ActiveWebTransportSession session,
  ) async {
    final operation = await _waitForWebTransportOperation(
      DartHttpNative.webTransportOpenBidirectionalStream(session.sessionId),
      'bidirectional stream open',
    );
    final stream = _registerWebTransportPersistentStreamFromOperation(session, operation);
    _drainWebTransportStreamChunks(stream.id);
    return WebTransportBidirectionalStream(receive: stream.receive, send: stream.send);
  }

  _ActiveWebTransportStream _registerWebTransportPersistentStreamFromOperation(
    _ActiveWebTransportSession session,
    NativeWebTransportOperation operation,
  ) => _registerWebTransportPersistentStream(
    session,
    NativeWebTransportStreamInfo(
      sessionId: operation.sessionId,
      streamId: operation.streamId,
      protocolId: operation.protocolId,
      kind: operation.kind == 1 ? 3 : 4,
    ),
  );

  _ActiveWebTransportStream _registerWebTransportPersistentStream(
    _ActiveWebTransportSession session,
    NativeWebTransportStreamInfo info,
  ) {
    final existing = session.persistentStreams[info.streamId];
    if (existing != null) return existing;
    late final _ActiveWebTransportStream stream;
    final chunks = StreamController<BinaryPayloadLease>();
    final receive = WebTransportReceiveStream(
      id: info.streamId,
      protocolId: info.protocolId,
      leases: chunks.stream,
      stop: ([errorCode = 0]) async {
        await _waitForWebTransportOperation(
          DartHttpNative.webTransportStreamStop(info.streamId, errorCode),
          'stream stop',
        );
      },
    );
    final send = WebTransportSendStream(
      id: info.streamId,
      protocolId: info.protocolId,
      write: (value) => stream.enqueueSend(() async {
        await _waitForWebTransportOperation(
          DartHttpNative.webTransportStreamWrite(info.streamId, value),
          'stream write',
        );
      }),
      writeLease: (lease) => stream.enqueueSend(() async {
        try {
          final operationId = switch (lease) {
            NativeByteLease(:final bytesPointer, :final length) =>
              DartHttpNative.webTransportStreamWriteNative(
                info.streamId,
                bodyPtr: bytesPointer,
                bodyLength: length,
              ),
            _ => DartHttpNative.webTransportStreamWrite(info.streamId, lease.bytesView),
          };
          await _waitForWebTransportOperation(operationId, 'stream write');
        } finally {
          lease.close();
        }
      }),
      finish: () => stream.enqueueSend(() async {
        await _waitForWebTransportOperation(
          DartHttpNative.webTransportStreamFinish(info.streamId),
          'stream finish',
        );
      }),
      reset: ([errorCode = 0]) => stream.enqueueSend(() async {
        await _waitForWebTransportOperation(
          DartHttpNative.webTransportStreamReset(info.streamId, errorCode),
          'stream reset',
        );
      }),
    );
    stream = _ActiveWebTransportStream(
      id: info.streamId,
      session: session,
      chunks: chunks,
      receive: receive,
      send: send,
    );
    session.persistentStreams[info.streamId] = stream;
    return stream;
  }

  _ActiveWebTransportStream? _activeWebTransportStream(int streamId) {
    for (final session in _activeWebTransportSessions.values) {
      final stream = session.persistentStreams[streamId];
      if (stream != null) return stream;
    }
    return null;
  }

  SseResponse? _resolveSseResponse(Object? body, ResponseBuilder response) {
    if (body case final SseResponse response) {
      return response;
    }

    final override = response.hasBodyOverride ? response.bodyOverride : null;
    return override is SseResponse ? override : null;
  }

  BinaryStreamResponse? _resolveBinaryStreamResponse(Object? body, ResponseBuilder response) {
    if (body case final BinaryStreamResponse response) {
      return response;
    }

    final override = response.hasBodyOverride ? response.bodyOverride : null;
    return override is BinaryStreamResponse ? override : null;
  }

  NativeBinaryStreamResponse? _resolveNativeBinaryStreamResponse(
    Object? body,
    ResponseBuilder response,
  ) {
    if (body case final NativeBinaryStreamResponse response) {
      return response;
    }

    final override = response.hasBodyOverride ? response.bodyOverride : null;
    return override is NativeBinaryStreamResponse ? override : null;
  }

  void _streamNativeBinaryResponse(int requestId, NativeBinaryStreamResponse response) {
    final transfer = response.body.takeNative();
    DartHttpNative.startNativeBinaryStreamResponse(
      requestId,
      status: response.status,
      contentType: response.contentType,
      contentLength: response.contentLength,
      headers: response.headers,
      body: transfer,
    );
  }

  Future<void> _streamBinaryResponse(int requestId, BinaryStreamResponse response) async {
    var started = false;
    try {
      started = DartHttpNative.startBinaryStreamResponse(
        requestId,
        status: response.status,
        contentType: response.contentType,
        contentLength: response.contentLength,
        headers: response.headers,
      );
      if (!started) {
        return;
      }

      await for (final chunk in response.body) {
        if (!DartHttpNative.sendBinaryStreamChunk(requestId, chunk)) {
          break;
        }
      }
    } finally {
      try {
        if (started) {
          DartHttpNative.finishBinaryStreamResponse(requestId);
        }
      } finally {
        await response.dispose();
      }
    }
  }

  Future<void> _streamSseResponse(int requestId, SseResponse response) async {
    final started = DartHttpNative.startSseResponse(
      requestId,
      status: response.status,
      headers: _defaultSseHeaders(response.headers),
    );
    if (!started) {
      return;
    }

    try {
      await for (final event in response.events) {
        if (!DartHttpNative.sendSseChunk(requestId, event.encode())) {
          break;
        }
      }
    } finally {
      DartHttpNative.finishSseResponse(requestId);
    }
  }

  List<HttpHeader> _defaultSseHeaders(List<HttpHeader> headers) {
    final hasCacheControl = headers.any((header) => header.name.toLowerCase() == 'cache-control');
    final hasBufferingHint = headers.any(
      (header) => header.name.toLowerCase() == 'x-accel-buffering',
    );

    return [
      ...headers,
      if (!hasCacheControl) const HttpHeader('Cache-Control', 'no-cache'),
      if (!hasBufferingHint) const HttpHeader('X-Accel-Buffering', 'no'),
    ];
  }

  String _transportOperationId(
    TransportRequest request,
    CompiledRouteTable<TServices> compiledRoutes,
  ) {
    return switch (request.requestKind) {
          TransportRequestKind.http =>
            compiledRoutes.routesById[request.routeId]?.options.operationId,
          TransportRequestKind.webSocket =>
            compiledRoutes.webSocketRoutesById[request.routeId]?.options.operationId,
          TransportRequestKind.webTransport =>
            compiledRoutes.webTransportRoutesById[request.routeId]?.options.operationId,
        } ??
        request.routeId;
  }

  void _respondServerError(int requestId) {
    final response = encodeServerError();
    DartHttpNative.tryRespond(
      requestId,
      status: response.status,
      contentType: response.contentType,
      body: response.bodyBytes,
      headers: response.headers,
    );
  }

  TServices _createServices() {
    final factory = services;
    if (factory != null) {
      return factory();
    }

    if (null is TServices) {
      return null as TServices;
    }

    throw StateError('No services factory configured. Pass services: () => ... to DartHttp.');
  }

  CompiledRouteTable<TServices> _compileRoutes() {
    return CompiledRouteTable.fromRegistrations(routeRegistry.registrations);
  }
}

Object? _normalizeWebSocketJson(Object? value) {
  switch (value) {
    case null:
    case bool():
    case num():
    case String():
      return value;
    case List():
      return value.map(_normalizeWebSocketJson).toList(growable: false);
    case Map():
      return {
        for (final entry in value.entries)
          entry.key.toString(): _normalizeWebSocketJson(entry.value),
      };
    case JsonEncodable():
      return _normalizeWebSocketJson(value.toJson());
    default:
      throw StateError('WebSocket payload of type ${value.runtimeType} is not JSON encodable.');
  }
}

Future<void> _sendWebSocketText(int sessionId, String value) async {
  if (!DartHttpNative.webSocketSendText(sessionId, value)) {
    throw StateError('Failed to send WebSocket text frame for $sessionId.');
  }
}

Future<void> _sendWebSocketBinary(int sessionId, List<int> value) async {
  if (!DartHttpNative.webSocketSendBinary(sessionId, value)) {
    throw StateError('Failed to send WebSocket binary frame for $sessionId.');
  }
}

Future<void> _sendWebSocketBinaryLease(int sessionId, BinaryPayloadLease lease) async {
  final sent = switch (lease) {
    NativeByteLease(:final bytesPointer, :final length) => DartHttpNative.webSocketSendNativeBinary(
      sessionId,
      bodyPtr: bytesPointer,
      bodyLength: length,
    ),
    _ => DartHttpNative.webSocketSendBinary(sessionId, lease.bytesView),
  };
  if (!sent) {
    throw StateError('Failed to send WebSocket binary frame for $sessionId.');
  }
}

Future<void> _sendWebSocketJson(int sessionId, Object? value) async {
  final encoded = jsonEncode(_normalizeWebSocketJson(value));
  if (!DartHttpNative.webSocketSendText(sessionId, encoded)) {
    throw StateError('Failed to send WebSocket JSON frame for $sessionId.');
  }
}

Future<void> _sendWebTransportDatagram(int sessionId, List<int> value) async {
  if (!DartHttpNative.webTransportSendDatagram(sessionId, value)) {
    throw StateError('Failed to send WebTransport datagram for $sessionId.');
  }
}

Future<void> _sendWebTransportDatagramLease(int sessionId, BinaryPayloadLease lease) async {
  final sent = switch (lease) {
    NativeByteLease(:final bytesPointer, :final length) =>
      DartHttpNative.webTransportSendNativeDatagram(
        sessionId,
        bodyPtr: bytesPointer,
        bodyLength: length,
      ),
    _ => DartHttpNative.webTransportSendDatagram(sessionId, lease.bytesView),
  };
  if (!sent) {
    throw StateError('Failed to send WebTransport datagram for $sessionId.');
  }
}

Future<void> _sendWebTransportStream(int sessionId, List<int> value) async {
  if (!DartHttpNative.webTransportSendStream(sessionId, value)) {
    throw StateError('Failed to send WebTransport stream for $sessionId.');
  }
}

Future<void> _sendWebTransportStreamLease(int sessionId, BinaryPayloadLease lease) async {
  final sent = switch (lease) {
    NativeByteLease(:final bytesPointer, :final length) =>
      DartHttpNative.webTransportSendNativeStream(
        sessionId,
        bodyPtr: bytesPointer,
        bodyLength: length,
      ),
    _ => DartHttpNative.webTransportSendStream(sessionId, lease.bytesView),
  };
  if (!sent) {
    throw StateError('Failed to send WebTransport stream payload for $sessionId.');
  }
}

WebSocketMessage _decodeWebSocketMessage(NativeWebSocketMessage message) {
  return switch (message.kind) {
    NativeWebSocketMessageKind.text => WebSocketMessage.text(utf8.decode(message.body!)),
    NativeWebSocketMessageKind.binary => WebSocketMessage.leasedBinary(message.bodyLease!),
  };
}

typedef _NativeTransportEvent = Void Function(Int32, Int64);

final class _RustTransportSession {
  _RustTransportSession._({
    required this.serverId,
    required this.host,
    required this.port,
    required this.callback,
  });

  final int serverId;
  final String host;
  final int port;
  final NativeCallable<_NativeTransportEvent> callback;
  var _closed = false;

  static Future<_RustTransportSession> start({
    required String host,
    required int requestedPort,
    required int workers,
    required String routesJson,
    required String middlewaresJson,
    required Future<void> Function(int eventKind, int eventId) onTransportEvent,
  }) async {
    late final NativeCallable<_NativeTransportEvent> callback;

    void handleTransportEvent(int eventKind, int eventId) {
      unawaited(onTransportEvent(eventKind, eventId));
    }

    callback = NativeCallable<_NativeTransportEvent>.listener(handleTransportEvent);
    final startResult = DartHttpNative.startServer(
      host,
      requestedPort,
      workers: workers,
      routesJson: routesJson,
      middlewaresJson: middlewaresJson,
      callback: callback.nativeFunction,
    );
    if (startResult.port <= 0 || startResult.serverId <= 0) {
      callback.close();
      throw StateError('Failed to start Rust-backed transport runtime.');
    }

    return _RustTransportSession._(
      serverId: startResult.serverId,
      host: host,
      port: startResult.port,
      callback: callback,
    );
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    DartHttpNative.stopServerById(serverId);
    callback.close();
  }
}

String _middlewaresJson(List<RustMiddleware> middlewares) {
  return jsonEncode({'middlewares': middlewares.map(_middlewareJson).toList(growable: false)});
}

Map<String, Object?> _middlewareJson(RustMiddleware middleware) {
  return {
    'name': middleware.name,
    if (middleware.configuration case final configuration?)
      'configuration': _middlewareConfigurationJson(configuration),
  };
}

Map<String, Object?> _middlewareConfigurationJson(RustMiddlewareConfiguration configuration) {
  return switch (configuration) {
    RustCorsMiddlewareConfiguration() => {
      'allowOrigins': configuration.allowOrigins,
      'allowHeaders': configuration.allowHeaders,
    },
    RustTracingMiddlewareConfiguration() => {
      if (configuration.openTelemetry case final openTelemetry?)
        'openTelemetry': {
          'serviceName': openTelemetry.serviceName,
          'endpoint': openTelemetry.endpoint,
        },
    },
    RustBodyLimitMiddlewareConfiguration() => {'maxBytes': configuration.maxBytes},
  };
}

final class _ActiveWebSocketSession {
  _ActiveWebSocketSession(this.messages);

  final StreamController<WebSocketMessage> messages;
  final Set<BinaryPayloadLease> _leases = <BinaryPayloadLease>{};
  Future<void>? task;

  void track(BinaryPayloadLease lease) {
    _leases.removeWhere((value) => value.isClosed);
    _leases.add(lease);
  }

  void closeLeases() {
    for (final lease in _leases) {
      lease.close();
    }
    _leases.clear();
  }
}

final class _ActiveWebTransportSession {
  _ActiveWebTransportSession(
    this.sessionId,
    this.datagrams,
    this.streams,
    this.unidirectional,
    this.bidirectional,
  );

  final int sessionId;
  final StreamController<BinaryPayloadLease> datagrams;
  final StreamController<BinaryPayloadLease> streams;
  final StreamController<WebTransportReceiveStream> unidirectional;
  final StreamController<WebTransportBidirectionalStream> bidirectional;
  final Map<int, _ActiveWebTransportStream> persistentStreams = <int, _ActiveWebTransportStream>{};
  final Set<BinaryPayloadLease> _leases = <BinaryPayloadLease>{};
  Future<void>? task;

  void track(BinaryPayloadLease lease) {
    _leases.removeWhere((value) => value.isClosed);
    _leases.add(lease);
  }

  void closeLeases() {
    for (final lease in _leases) {
      lease.close();
    }
    _leases.clear();
  }

  Future<void> close() async {
    await datagrams.close();
    await streams.close();
    await unidirectional.close();
    await bidirectional.close();
    for (final stream in persistentStreams.values) {
      if (!stream.chunks.isClosed) await stream.chunks.close();
    }
  }
}

final class _ActiveWebTransportStream {
  _ActiveWebTransportStream({
    required this.id,
    required this.session,
    required this.chunks,
    required this.receive,
    required this.send,
  });

  final int id;
  final _ActiveWebTransportSession session;
  final StreamController<BinaryPayloadLease> chunks;
  final WebTransportReceiveStream receive;
  final WebTransportSendStream send;
  Future<void> _sendTail = Future<void>.value();

  Future<void> enqueueSend(Future<void> Function() action) {
    final completer = Completer<void>();
    _sendTail = _sendTail.then(
      (_) async {
        try {
          await action();
          completer.complete();
        } catch (error, stackTrace) {
          completer.completeError(error, stackTrace);
        }
      },
      onError: (_) async {
        try {
          await action();
          completer.complete();
        } catch (error, stackTrace) {
          completer.completeError(error, stackTrace);
        }
      },
    );
    return completer.future;
  }
}
