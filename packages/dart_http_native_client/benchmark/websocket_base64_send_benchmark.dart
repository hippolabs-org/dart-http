import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_http_core/dart_http_core.dart';
import 'package:dart_http_native_client/dart_http_native_client.dart';

const _prefix = '{"type":"input_audio_buffer.append","audio":"';
const _suffix = '"}';

Future<void> main(List<String> arguments) async {
  final iterations = arguments.isEmpty ? 256 : int.parse(arguments.first);
  if (iterations < 1 || iterations > 1024) {
    throw ArgumentError.value(iterations, 'iterations', 'Must be between 1 and 1024.');
  }

  stdout.writeln('WebSocket base64 text send benchmark ($iterations messages per sample)');
  stdout.writeln('Lower microseconds/message is better; throughput counts raw input bytes.');
  for (final size in const <int>[640, 960, 64 * 1024]) {
    await _benchmarkSize(size: size, iterations: iterations);
  }
}

Future<void> _benchmarkSize({required int size, required int iterations}) async {
  final dartSamples = <Duration>[];
  final nativeSamples = <Duration>[];
  for (var sample = 0; sample < 6; sample++) {
    final dart = await _runTrial(size: size, iterations: iterations, native: false);
    final native = await _runTrial(size: size, iterations: iterations, native: true);
    if (sample != 0) {
      dartSamples.add(dart);
      nativeSamples.add(native);
    }
  }
  final dart = _median(dartSamples);
  final native = _median(nativeSamples);
  final dartMicros = dart.inMicroseconds / iterations;
  final nativeMicros = native.inMicroseconds / iterations;
  final speedup = dartMicros / nativeMicros;
  stdout.writeln(
    '${size.toString().padLeft(6)} bytes  '
    'Dart ${dartMicros.toStringAsFixed(1).padLeft(8)} us/msg  '
    'native ${nativeMicros.toStringAsFixed(1).padLeft(8)} us/msg  '
    '${speedup.toStringAsFixed(2)}x  '
    '${_mibPerSecond(size, nativeMicros).toStringAsFixed(1)} MiB/s native',
  );
}

Future<Duration> _runTrial({
  required int size,
  required int iterations,
  required bool native,
}) async {
  final payload = List<int>.generate(size, (index) => index % 251, growable: false);
  final expectedTextLength = _prefix.length + ((size + 2) ~/ 3) * 4 + _suffix.length;
  final receivedAll = Completer<void>();
  var receivedCount = 0;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    socket.listen((message) {
      if (message is! String || message.length != expectedTextLength) {
        if (!receivedAll.isCompleted) {
          receivedAll.completeError(StateError('Received an invalid benchmark message.'));
        }
        return;
      }
      receivedCount++;
      if (receivedCount == iterations && !receivedAll.isCompleted) receivedAll.complete();
    }, onError: receivedAll.completeError);
    for (var index = 0; index < iterations; index++) {
      socket.add(payload);
    }
  });

  final transport = await NativeHttpClientTransport.open(
    webSocketIncomingCapacity: 1024,
    webSocketOutgoingCapacity: 1024,
  );
  final socket = await transport.connect(
    DartHttpClientWebSocketRequest(
      uri: Uri.parse('ws://${server.address.host}:${server.port}/benchmark'),
    ),
  );
  final leases = <BinaryPayloadLease>[];
  final leasesReady = Completer<void>();
  final subscription = socket.messages.listen((message) {
    leases.add(message.takeBinaryLease());
    if (leases.length == iterations) leasesReady.complete();
  }, onError: leasesReady.completeError);

  try {
    await leasesReady.future;
    final stopwatch = Stopwatch()..start();
    for (final lease in leases) {
      if (native) {
        await socket.sendTextBase64Lease(lease, prefix: _prefix, suffix: _suffix);
      } else {
        try {
          final encoded = base64Encode(lease.bytesView);
          await socket.sendText('$_prefix$encoded$_suffix');
        } finally {
          lease.close();
        }
      }
    }
    await receivedAll.future;
    stopwatch.stop();
    return stopwatch.elapsed;
  } finally {
    for (final lease in leases) {
      lease.close();
    }
    await subscription.cancel();
    await socket.close();
    transport.close();
    await server.close(force: true);
  }
}

Duration _median(List<Duration> values) {
  values.sort((left, right) => left.compareTo(right));
  return values[values.length ~/ 2];
}

double _mibPerSecond(int bytes, double micros) => bytes / (1024 * 1024) / (micros / 1000000);
