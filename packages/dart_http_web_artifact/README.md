# dart_http_web_artifact

Serve a prebuilt web application directly from a Dart HTTP server. The package
keeps static hosting separate from the server runtime and works with Flutter,
Jaspr, or any other directory-based web build.

```dart
import 'package:dart_http_server/dart_http_server.dart';
import 'package:dart_http_web_artifact/dart_http_web_artifact.dart';

final app = DartHttp<void>();

app.serveWebArtifact(
  WebArtifact.directory(
    '/app/web',
    spaFallback: true,
    headers: const {
      'Content-Security-Policy': "default-src 'self'",
    },
  ),
);
```

The host streams files, rejects traversal outside the artifact directory,
detects content types, emits validators for conditional requests, and serves
`file.br` or `file.gz` when a compatible precompressed sibling exists. The
entry point and SPA fallbacks use `no-cache`; other assets use a configurable
cache policy.

Generate precompressed files during the application build. Runtime compression
middleware remains useful for dynamic responses, while precompressed artifacts
avoid recompressing the same large JavaScript and WebAssembly files on every
request.
