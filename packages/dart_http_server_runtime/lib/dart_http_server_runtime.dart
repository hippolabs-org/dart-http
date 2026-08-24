/// Concrete HTTP runtime library for Dart HTTP.
///
/// Import this library when you want direct access to the runtime surface,
/// including [DartHttp], the re-exported `dart_http_core` contracts, JSON
/// Schema registry types, and the native transport bridge.
library;

export 'package:dart_http_core/dart_http_core.dart';
export 'package:native_exchange/native_exchange_ffi.dart' show NativeByteLease;

export 'src/native/dart_http_native.dart';
export 'src/runtime/dart_http_codec.dart';
export 'src/runtime/dart_http_server.dart';
export 'src/runtime/dart_http_server_instance.dart';
export 'src/runtime/native_binary_stream_response.dart';
export 'src/runtime/native_request.dart'
    show NativeMultipartField, NativeMultipartFile, NativeMultipartForm, NativeRequestBody;
export 'src/runtime/open_api_document.dart';
export 'src/runtime/open_telemetry_config.dart';
export 'src/runtime/request_input_multipart.dart' show MultipartRequestInput;
export 'src/runtime/rust_middleware.dart';
export 'src/runtime/transport_request.dart';
