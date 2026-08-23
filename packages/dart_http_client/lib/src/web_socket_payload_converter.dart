import 'dart:typed_data';

import 'web_socket_payload_converter_stub.dart'
    if (dart.library.js_interop) 'web_socket_payload_converter_web.dart'
    as platform;

Future<Uint8List?> webSocketBlobBytes(Object? value) {
  return platform.webSocketBlobBytes(value);
}
