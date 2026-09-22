import 'dart:convert';
import 'dart:typed_data';

import 'package:jaspr/jaspr.dart' show Component;
import 'package:jaspr/server.dart' as jaspr_server show Jaspr, Request, renderComponent;

typedef _RenderedJasprResponse = ({
  int statusCode,
  Uint8List body,
  Map<String, List<String>> headers,
});

/// Renders Jaspr components into HTML strings.
final class JasprRenderer {
  const JasprRenderer._();

  /// Ensures Jaspr has been initialized for server-side rendering.
  static void ensureInitialized() {
    if (!jaspr_server.Jaspr.isInitialized) {
      jaspr_server.Jaspr.initializeApp();
    }
  }

  /// Renders [component] to an HTML string.
  ///
  /// When [standalone] is `false`, Jaspr produces a full HTML document. When it
  /// is `true`, only the component subtree is rendered.
  static Future<String> renderString(
    Component component, {
    jaspr_server.Request? request,
    bool standalone = false,
  }) async {
    final rendered = await _render(component, request: request, standalone: standalone);
    return utf8.decode(rendered.body);
  }

  static Future<_RenderedJasprResponse> _render(
    Component component, {
    jaspr_server.Request? request,
    required bool standalone,
  }) async {
    ensureInitialized();
    return jaspr_server.renderComponent(component, request: request, standalone: standalone);
  }
}
