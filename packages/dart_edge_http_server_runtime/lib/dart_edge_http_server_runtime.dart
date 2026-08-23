/// Concrete HTTP runtime library for Dart Edge.
///
/// Import this library when you want direct access to the runtime surface,
/// including [DartEdge], the re-exported `dart_edge_core` contracts, JSON
/// Schema registry types, and the native transport bridge.
library;

export 'package:dart_edge_core/dart_edge_core.dart';

export 'src/native/dart_edge_native.dart';
export 'src/runtime/dart_edge_codec.dart';
export 'src/runtime/dart_edge_http_server.dart';
export 'src/runtime/dart_edge_server.dart';
export 'src/runtime/native_binary_stream_response.dart';
export 'src/runtime/native_request.dart'
    show NativeMultipartField, NativeMultipartFile, NativeMultipartForm, NativeRequestBody;
export 'src/runtime/open_api_document.dart';
export 'src/runtime/open_telemetry_config.dart';
export 'src/runtime/request_input_multipart.dart' show MultipartRequestInput;
export 'src/runtime/rust_middleware.dart';
export 'src/runtime/transport_request.dart';
