import 'package:dart_edge_http_server_runtime/dart_edge_http_server_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('loads the bundled Rust runtime asset', () {
    expect(DartEdgeNative.abiVersion, 17);
    expect(DartEdgeNative.hasBundledRuntime, isTrue);
  });
}
