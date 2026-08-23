import 'dart:convert';

import 'package:dart_http_server_runtime/dart_http_server_runtime.dart';

/// Convenience helpers for mounting OpenAPI-related routes on a [DartHttp] app.
///
/// These helpers define the intended app-facing integration points for serving
/// an OpenAPI document and a Swagger UI alongside your routes.
final class OpenApiHelpers {
  const OpenApiHelpers._();

  /// Mounts the OpenAPI JSON document for [app] at [path].
  ///
  /// This helper is the app-facing hook where generated or runtime-produced
  /// OpenAPI JSON should be exposed.
  static void mountJson<TServices>(DartHttp<TServices> app, {required String path}) {
    app.get(
      path,
      options: RouteOptions(
        summary: 'Serve the generated OpenAPI document.',
        tags: <String>['openapi'],
        exposure: RouteExposure.none,
        success: ResponseSpec.json(),
      ),
      handler: (_) => RawResponse.encoded(
        status: 200,
        contentType: 'application/json; charset=utf-8',
        body: const JsonEncoder.withIndent('  ').convert(app.buildOpenApiDocumentJson()),
      ),
    );
  }

  /// Mounts a Swagger UI page for [app] at [path].
  ///
  /// [specPath] should point at the JSON document mounted with [mountJson].
  static void mountSwaggerUi<TServices>(
    DartHttp<TServices> app, {
    required String path,
    required String specPath,
  }) {
    app.get(
      path,
      options: RouteOptions(
        summary: 'Serve a Swagger UI page for the generated OpenAPI document.',
        tags: <String>['openapi'],
        exposure: RouteExposure.none,
        success: ResponseSpec.html(),
      ),
      handler: (_) => RawResponse.encoded(
        status: 200,
        contentType: 'text/html; charset=utf-8',
        body: _swaggerUiPage(specPath),
      ),
    );
  }
}

String _swaggerUiPage(String specPath) {
  return '''
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Swagger UI</title>
    <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css">
    <style>
      html, body {
        margin: 0;
        padding: 0;
        background: #fafafa;
      }
    </style>
  </head>
  <body>
    <div id="swagger-ui"></div>
    <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
    <script>
      window.ui = SwaggerUIBundle({
        url: ${jsonEncode(specPath)},
        dom_id: '#swagger-ui',
      });
    </script>
  </body>
</html>
''';
}
