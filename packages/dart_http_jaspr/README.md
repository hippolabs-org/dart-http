# dart_http_jaspr

Render Jaspr components and mount complete Jaspr applications on Dart HTTP
routers. App mounting uses `dart_http_shelf` because Jaspr's server API exposes
a Shelf handler.

```dart
import 'package:dart_http_jaspr/dart_http_jaspr.dart';
import 'package:dart_http_server/dart_http_server.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart' show Component;

final app = DartHttp<void>(services: () {});

app.mountJasprApp(
  div([Component.text('Hello from Jaspr')]),
  catchAllPath: '/docs/<docsPath*>',
  handlerPath: '/docs',
);
```

Use `JasprRenderer.renderString(...)` when a route, email, or preview needs an
HTML string without mounting a complete application.
