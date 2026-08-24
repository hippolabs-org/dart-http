import 'dart:ffi';

import 'package:dart_http_server_runtime/src/native/generated_bindings.dart' as gen;
import 'package:dart_http_server_runtime/src/native/native_transport_web_transport.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

void main() {
  test('WebTransport datagrams retain their native message handle', () {
    final bytes = calloc<Uint8>(3);
    bytes.asTypedList(3).setAll(0, [4, 5, 6]);
    final native = calloc<gen.NativeWebTransportDatagram>();
    native.ref
      ..session_id = 42
      ..body.ptr = bytes
      ..body.len = 3;
    var releaseCount = 0;

    final datagram = decodeNativeWebTransportDatagram(
      native,
      release: () {
        releaseCount += 1;
        calloc.free(bytes);
        calloc.free(native);
      },
    );

    expect(datagram.sessionId, 42);
    expect(datagram.bodyLease.bytesPointer, bytes);
    expect(datagram.bodyLease.bytesView, [4, 5, 6]);
    expect(releaseCount, 0);
    datagram.bodyLease.close();
    expect(releaseCount, 1);
  });

  test('WebTransport streams retain their native message handle', () {
    final bytes = calloc<Uint8>(2);
    bytes.asTypedList(2).setAll(0, [7, 8]);
    final native = calloc<gen.NativeWebTransportStream>();
    native.ref
      ..session_id = 43
      ..body.ptr = bytes
      ..body.len = 2;
    var releaseCount = 0;

    final stream = decodeNativeWebTransportStream(
      native,
      release: () {
        releaseCount += 1;
        calloc.free(bytes);
        calloc.free(native);
      },
    );

    expect(stream.sessionId, 43);
    expect(stream.bodyLease.bytesPointer, bytes);
    expect(stream.bodyLease.bytesView, [7, 8]);
    expect(releaseCount, 0);
    stream.bodyLease.close();
    expect(releaseCount, 1);
  });

  test('WebTransport stream chunks retain their native chunk handle', () {
    final bytes = calloc<Uint8>(3);
    bytes.asTypedList(3).setAll(0, [9, 10, 11]);
    final native = calloc<gen.NativeWebTransportStreamChunk>();
    native.ref
      ..stream_id = 44
      ..body.ptr = bytes
      ..body.len = 3;
    var releaseCount = 0;

    final chunk = decodeNativeWebTransportStreamChunk(
      native,
      release: () {
        releaseCount += 1;
        calloc.free(bytes);
        calloc.free(native);
      },
    );

    expect(chunk.streamId, 44);
    expect(chunk.bodyLease.bytesPointer, bytes);
    expect(chunk.bodyLease.bytesView, [9, 10, 11]);
    expect(releaseCount, 0);
    chunk.bodyLease.close();
    expect(releaseCount, 1);
  });
}
