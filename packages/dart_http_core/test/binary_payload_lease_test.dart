import 'dart:typed_data';

import 'package:dart_http_core/dart_http_core.dart';
import 'package:test/test.dart';

void main() {
  test('Native Exchange leases adapt without copying their byte view', () {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final exchangeLease = DartByteLease(bytes);
    final lease = BinaryPayloadLease.fromByteLease(exchangeLease);

    expect(identical(lease.bytesView, bytes), isTrue);
    expect(lease.length, 3);
    lease.close();
    expect(exchangeLease.isClosed, isTrue);
  });

  test('WebSocket bytes copy and release a native-style lease lazily', () {
    final lease = _TrackingBinaryPayloadLease([1, 2, 3]);
    final message = WebSocketMessage.leasedBinary(lease);

    expect(message.hasBinaryLease, isTrue);
    expect(lease.closeCount, 0);
    expect(message.bytes, [1, 2, 3]);
    expect(message.hasBinaryLease, isFalse);
    expect(lease.closeCount, 1);
    expect(message.bytes, [1, 2, 3]);
  });

  test('WebSocket leasedBinary transfers ownership without copying', () async {
    final lease = _TrackingBinaryPayloadLease([4, 5, 6]);
    final incoming = IncomingWebSocketMessages(Stream.value(WebSocketMessage.leasedBinary(lease)));

    final received = await incoming.leasedBinary().single;

    expect(identical(received, lease), isTrue);
    expect(received.bytesView, [4, 5, 6]);
    expect(lease.closeCount, 0);
    received.close();
    expect(lease.closeCount, 1);
  });

  test('WebSocket text filtering releases skipped binary frames', () async {
    final lease = _TrackingBinaryPayloadLease([7, 8]);
    final incoming = IncomingWebSocketMessages(
      Stream.fromIterable([WebSocketMessage.leasedBinary(lease), WebSocketMessage.text('control')]),
    );

    expect(await incoming.text().toList(), ['control']);
    expect(lease.closeCount, 1);
  });

  test('WebTransport compatibility access copies and closes leases', () async {
    final datagram = _TrackingBinaryPayloadLease([9, 10]);
    final stream = _TrackingBinaryPayloadLease([11, 12]);

    final datagramBytes = await IncomingWebTransportDatagrams.leased(Stream.value(datagram))
        .datagrams()
        .single;
    final streamBytes = await IncomingWebTransportStreams.leased(Stream.value(stream))
        .streams()
        .single;

    expect(datagramBytes, [9, 10]);
    expect(streamBytes, [11, 12]);
    expect(datagram.closeCount, 1);
    expect(stream.closeCount, 1);
  });

  test('leased send helpers consume payload ownership', () async {
    final webSocketLease = _TrackingBinaryPayloadLease([1]);
    final datagramLease = _TrackingBinaryPayloadLease([2]);
    final streamLease = _TrackingBinaryPayloadLease([3]);
    final sent = <List<int>>[];
    final webSocket = WebSocketContext<void>(
      services: null,
      sendBinaryLease: (lease) async => sent.add(lease.copyBytes()),
    );
    final webTransport = WebTransportContext<void>(
      services: null,
      sendDatagramLease: (lease) async => sent.add(lease.copyBytes()),
      sendStreamLease: (lease) async => sent.add(lease.copyBytes()),
    );

    await webSocket.sendBinaryLease(webSocketLease);
    await webTransport.sendDatagramLease(datagramLease);
    await webTransport.sendStreamLease(streamLease);

    expect(sent, [
      [1],
      [2],
      [3],
    ]);
    expect(webSocketLease.closeCount, 1);
    expect(datagramLease.closeCount, 1);
    expect(streamLease.closeCount, 1);
  });

  test('persistent WebTransport stream exposes incremental leases', () async {
    final first = _TrackingBinaryPayloadLease([1, 2]);
    final second = _TrackingBinaryPayloadLease([3, 4]);
    var stoppedWith = -1;
    final stream = WebTransportReceiveStream(
      id: 7,
      protocolId: 12,
      leases: Stream.fromIterable([first, second]),
      stop: ([errorCode = 0]) async => stoppedWith = errorCode,
    );

    expect(stream.id, 7);
    expect(stream.protocolId, 12);
    expect(await stream.chunks().toList(), [
      [1, 2],
      [3, 4],
    ]);
    expect(first.closeCount, 1);
    expect(second.closeCount, 1);
    await stream.stop(19);
    expect(stoppedWith, 19);
  });

  test('persistent WebTransport send stream forwards its lifecycle', () async {
    final calls = <Object>[];
    final lease = _TrackingBinaryPayloadLease([5, 6]);
    final stream = WebTransportSendStream(
      id: 8,
      protocolId: 16,
      write: (value) async => calls.add(List<int>.from(value)),
      writeLease: (value) async {
        calls.add(value.copyBytes());
        value.close();
      },
      finish: () async => calls.add('finish'),
      reset: ([errorCode = 0]) async => calls.add(errorCode),
    );

    await stream.write([1, 2]);
    await stream.writeLease(lease);
    await stream.finish();
    await stream.reset(23);

    expect(calls, [
      [1, 2],
      [5, 6],
      'finish',
      23,
    ]);
    expect(lease.closeCount, 1);
  });
}

final class _TrackingBinaryPayloadLease implements BinaryPayloadLease {
  _TrackingBinaryPayloadLease(List<int> bytes) : _bytes = Uint8List.fromList(bytes);

  Uint8List? _bytes;
  int closeCount = 0;

  @override
  Uint8List get bytesView => _bytes ?? (throw StateError('Tracking lease is closed.'));

  @override
  bool get isClosed => _bytes == null;

  @override
  int get length => bytesView.length;

  @override
  void close() {
    if (_bytes == null) return;
    _bytes = null;
    closeCount += 1;
  }

  @override
  Uint8List copyBytes() => Uint8List.fromList(bytesView);

  @override
  Uint8List takeBytes() {
    try {
      return copyBytes();
    } finally {
      close();
    }
  }
}
