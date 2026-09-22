import 'package:dart_http_core/dart_http_core.dart';
import 'package:dart_http_shelf/dart_http_shelf.dart';
import 'package:jaspr/jaspr.dart' show Component;
import 'package:jaspr/server.dart' as jaspr_server show Handler, Jaspr, Request, Response, serveApp;
// Jaspr exposes fileHandler customization from createHandler, but serveApp does
// not forward it yet.
// ignore: implementation_imports
import 'package:jaspr/src/server/server_handler.dart' as jaspr_server_internal show createHandler;

import 'jaspr_renderer.dart';

/// Handles Jaspr static asset requests before app rendering.
typedef JasprStaticFileHandler = jaspr_server.Handler;

/// Mounts a Jaspr component app onto Dart HTTP routes.
extension JasprAppRouterExtensions<TServices> on Router<TServices> {
  /// Mounts [app] on one catch-all route or on each explicit path.
  void mountJasprApp(
    Component app, {
    String? catchAllPath,
    Iterable<String> paths = const <String>['/'],
    RouteOptions Function(String path)? routeOptions,
    List<Guard<TServices>>? guards,
    bool serveStaticFiles = true,
    JasprStaticFileHandler? staticFileHandler,
    String? handlerPath,
  }) {
    JasprRenderer.ensureInitialized();

    final handler = _createJasprAppHandler(
      app,
      serveStaticFiles: serveStaticFiles,
      staticFileHandler: staticFileHandler,
    );

    if (catchAllPath case final path?) {
      mountShelfHandler(
        handler,
        path: path,
        methods: const [HttpMethod.get],
        guards: guards,
        handlerPath: handlerPath,
        routeOptions: (method, path) =>
            routeOptions?.call(path) ??
            const RouteOptions(
              summary: 'Render the mounted Jaspr app.',
              exposure: RouteExposure.none,
              success: ResponseSpec.html(),
            ),
      );
      return;
    }

    final mountedPaths = <String>{};
    for (final path in paths) {
      if (!mountedPaths.add(path)) {
        continue;
      }

      mountShelfHandler(
        handler,
        path: path,
        methods: const [HttpMethod.get],
        guards: guards,
        handlerPath: handlerPath,
        routeOptions: (method, path) =>
            routeOptions?.call(path) ??
            RouteOptions(
              summary: 'Render Jaspr app route $path.',
              success: const ResponseSpec.html(),
            ),
      );
    }
  }
}

jaspr_server.Handler _createJasprAppHandler(
  Component app, {
  required bool serveStaticFiles,
  required JasprStaticFileHandler? staticFileHandler,
}) {
  if (serveStaticFiles && staticFileHandler == null) {
    return jaspr_server.serveApp((request, render) => render(app));
  }

  return jaspr_server_internal.createHandler(
    (request, render) => render((binding) {
      binding.initializeOptions(jaspr_server.Jaspr.options);
      binding.attachRootComponent(app);
    }),
    fileHandler: serveStaticFiles
        ? staticFileHandler
        : (jaspr_server.Request request) => jaspr_server.Response.notFound(''),
  );
}
