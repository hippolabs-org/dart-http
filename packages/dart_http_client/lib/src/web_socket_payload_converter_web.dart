import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<Uint8List?> webSocketBlobBytes(Object? value) async {
  final JSAny jsValue;
  try {
    jsValue = value as JSAny;
  } on TypeError {
    return null;
  }

  if (!jsValue.isA<web.Blob>()) {
    return null;
  }

  final blob = jsValue as web.Blob;
  final buffer = await blob.arrayBuffer().toDart;
  return Uint8List.view(buffer.toDart);
}
