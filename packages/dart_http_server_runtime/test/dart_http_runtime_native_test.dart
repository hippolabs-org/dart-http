import 'package:dart_http_server_runtime/dart_http_server_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('loads the bundled Rust runtime asset', () {
    expect(DartHttpNative.abiVersion, dartHttpServerRuntimeNativeAbiVersion);
    expect(dartHttpServerRuntimeNativeAbiVersion, 27);
    expect(DartHttpNative.hasBundledRuntime, isTrue);
  });

  test('decodes packed transport events with signed ids', () {
    for (final (kind, id) in [(1, 7), (13, -42), (16, (1 << 57) - 1), (13, -(1 << 57))]) {
      expect(DartHttpNative.decodeTransportEvent((id << 5) | kind), (kind, id));
    }
  });
}
