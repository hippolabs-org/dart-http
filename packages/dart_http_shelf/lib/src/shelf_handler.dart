import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_http_server/dart_http_server.dart';
import 'package:shelf/shelf.dart' as shelf;

/// Converts a completed Shelf response into a response understood by Dart HTTP.
typedef ShelfResponseAdapter<TServices> = FutureOr<Object> Function(
  RequestContext<TServices> context,
  shelf.Response response,
);

/// Adapts Shelf handlers so they can be mounted on a Dart HTTP router.
extension ShelfRouterExtensions<TServices> on Router<TServices> {
  /// Mounts [handler] on every requested HTTP method using one catch-all route.
  ///
  /// The default [path] forwards `/`, static assets, and nested routes to the
  /// same Shelf handler. Shelf response bodies remain streamed by default.
  void mountShelfHandler(
    shelf.Handler handler, {
    String path = '/<shelfPath*>',
    Iterable<HttpMethod> methods = HttpMethod.values,
    RouteOptions Function(HttpMethod method, String path)? routeOptions,
    List<Guard<TServices>>? guards,
    String? handlerPath,
    ShelfResponseAdapter<TServices>? responseAdapter,
  }) {
    final requestPath = joinRoutePath(prefix, path);
    for (final method in methods) {
      final routeOptionsValue =
          routeOptions?.call(method, path) ?? _defaultRouteOptions(method, path);

      Future<Object> routeHandler(RequestContext<TServices> context) async {
        final request = _shelfRequestFor(
          context,
          method: method,
          path: requestPath,
          handlerPath: handlerPath,
        );
        final response = await Future.value(handler(request));
        return await responseAdapter?.call(context, response) ?? shelfResponseToDartHttp(response);
      }

      switch (method) {
        case HttpMethod.get:
          get<Object>(path, options: routeOptionsValue, guards: guards, handler: routeHandler);
        case HttpMethod.post:
          post<Object>(path, options: routeOptionsValue, guards: guards, handler: routeHandler);
        case HttpMethod.put:
          put<Object>(path, options: routeOptionsValue, guards: guards, handler: routeHandler);
        case HttpMethod.patch:
          patch<Object>(path, options: routeOptionsValue, guards: guards, handler: routeHandler);
        case HttpMethod.delete:
          delete<Object>(path, options: routeOptionsValue, guards: guards, handler: routeHandler);
        case HttpMethod.head:
          head<Object>(path, options: routeOptionsValue, guards: guards, handler: routeHandler);
        case HttpMethod.options:
          options<Object>(path, options: routeOptionsValue, guards: guards, handler: routeHandler);
      }
    }
  }
}

/// Converts [response] without collecting its body into memory.
BinaryStreamResponse shelfResponseToDartHttp(shelf.Response response) {
  final contentType = response.headers['content-type'] ?? 'application/octet-stream';
  final contentLength = int.tryParse(response.headers['content-length'] ?? '');
  final headers = <HttpHeader>[
    for (final entry in response.headersAll.entries)
      if (entry.key.toLowerCase() != 'content-type' &&
          entry.key.toLowerCase() != 'content-length' &&
          entry.key.toLowerCase() != 'transfer-encoding')
        for (final value in entry.value) HttpHeader(entry.key, value),
  ];

  return BinaryStreamResponse(
    status: response.statusCode,
    contentType: contentType,
    contentLength: contentLength,
    headers: headers,
    body: response.read(),
  );
}

shelf.Request _shelfRequestFor<TServices>(
  RequestContext<TServices> context, {
  required HttpMethod method,
  required String path,
  required String? handlerPath,
}) {
  final uri = Uri.http(
    context.req.header('host') ?? 'localhost',
    _pathForRequest(path, context.req.paramsMap),
    context.req.queryMap.isEmpty ? null : context.req.queryMap,
  );
  return shelf.Request(
    method.wireName,
    uri,
    headers: context.req.headersMap,
    handlerPath: handlerPath,
    body: _requestBody(context.req),
  );
}

Object? _requestBody(RequestInput input) {
  if (input.nativeBody case final nativeBody?) {
    return nativeBody.copyBytes();
  }

  final body = input.bodyOrNull;
  return switch (body) {
    final Uint8List value => value,
    final List<int> value => value,
    final String value => value,
    final Object value => utf8.encode(jsonEncode(value)),
    null => null,
  };
}

String _pathForRequest(String path, Map<String, String> params) {
  var resolved = path.isEmpty ? '/' : path;
  for (final entry in params.entries) {
    resolved = resolved
        .replaceAll(':${entry.key}*', entry.value)
        .replaceAll(':${entry.key}', entry.value)
        .replaceAll('<${entry.key}*>', entry.value)
        .replaceAll('<${entry.key}>', entry.value);
  }
  return resolved;
}

RouteOptions _defaultRouteOptions(HttpMethod method, String path) {
  return RouteOptions(
    operationId: _operationId(method, path),
    summary: 'Forward ${method.wireName} $path to a Shelf handler.',
    exposure: RouteExposure.none,
    success: const ResponseSpec.binary(),
  );
}

String _operationId(HttpMethod method, String path) {
  final words = path
      .replaceAll(RegExp(r'[^A-Za-z0-9]+'), ' ')
      .trim()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .map(_capitalize)
      .join();
  return words.isEmpty ? '${method.name}Shelf' : '${method.name}Shelf$words';
}

String _capitalize(String value) {
  if (value.isEmpty) return value;
  return '${value[0].toUpperCase()}${value.substring(1)}';
}
