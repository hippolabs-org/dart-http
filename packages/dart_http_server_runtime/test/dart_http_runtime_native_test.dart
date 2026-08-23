import 'package:dart_http_server_runtime/dart_http_server_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('loads the bundled Rust runtime asset', () {
    expect(DartHttpNative.abiVersion, 17);
    expect(DartHttpNative.hasBundledRuntime, isTrue);
  });
}
