/// Transport-agnostic core contracts for Dart Edge.
///
/// Import this library when you need the shared request/response/route/router
/// surface without taking a dependency on the native runtime package.
library;

export 'package:native_exchange/native_exchange.dart' show ByteLease, DartByteLease;

export 'src/annotations.dart';
export 'src/client/dart_edge_client_operation.dart';
export 'src/client/dart_edge_client_transport.dart';
export 'src/client/dart_edge_http_client.dart';
export 'src/context.dart';
export 'src/http.dart';
export 'src/isolate_worker.dart';
export 'src/router.dart';
export 'src/web_socket.dart';
export 'src/web_transport.dart';
