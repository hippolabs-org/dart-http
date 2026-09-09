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
  stdout.writeln('\nNative producer → base64 WebSocket pump:');
  await _benchmarkPump(size: 960, iterations: iterations);
  await _benchmarkPump(size: 64 * 1024, iterations: iterations > 128 ? 128 : iterations);
}

Future<void> _benchmarkSize({required int size, required int iterations}) async {
  final dartSamples = <Duration>[];
  final nativeSamples = <Duration>[];
  final queuedSamples = <Duration>[];
  for (var sample = 0; sample < 6; sample++) {
    final dart = await _runTrial(size: size, iterations: iterations, mode: _SendMode.dart);
    final native = await _runTrial(size: size, iterations: iterations, mode: _SendMode.native);
    final queued = await _runTrial(size: size, iterations: iterations, mode: _SendMode.queued);
    if (sample != 0) {
      dartSamples.add(dart);
      nativeSamples.add(native);
      queuedSamples.add(queued);
    }
  }
  final dart = _median(dartSamples);
  final native = _median(nativeSamples);
  final queued = _median(queuedSamples);
  final dartMicros = dart.inMicroseconds / iterations;
  final nativeMicros = native.inMicroseconds / iterations;
  final queuedMicros = queued.inMicroseconds / iterations;
  final speedup = dartMicros / nativeMicros;
  stdout.writeln(
    '${size.toString().padLeft(6)} bytes  '
    'Dart ${dartMicros.toStringAsFixed(1).padLeft(8)} us/msg  '
    'awaited ${nativeMicros.toStringAsFixed(1).padLeft(8)} us/msg '
    '${speedup.toStringAsFixed(2)}x  '
    'queued ${queuedMicros.toStringAsFixed(1).padLeft(8)} us/msg '
    '${(dartMicros / queuedMicros).toStringAsFixed(2)}x  '
    '${_mibPerSecond(size, queuedMicros).toStringAsFixed(1)} MiB/s queued',
  );
}

enum _SendMode { dart, native, queued }

Future<Duration> _runTrial({
  required int size,
  required int iterations,
  required _SendMode mode,
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
    if (mode == _SendMode.queued) {
      final queued = socket as DartHttpClientQueuedWebSocket;
      for (final lease in leases) {
        queued.enqueueTextBase64Lease(lease, prefix: _prefix, suffix: _suffix);
      }
      await queued.flush();
    } else {
      for (final lease in leases) {
        if (mode == _SendMode.native) {
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

Future<void> _benchmarkPump({required int size, required int iterations}) async {
  final samples = <Duration>[];
  for (var sample = 0; sample < 6; sample++) {
    final elapsed = await _runPumpTrial(size: size, iterations: iterations);
    if (sample != 0) samples.add(elapsed);
  }
  final elapsed = _median(samples);
  final micros = elapsed.inMicroseconds / iterations;
  stdout.writeln(
    '${size.toString().padLeft(6)} bytes  '
    '${micros.toStringAsFixed(1).padLeft(8)} us/source frame  '
    '${_mibPerSecond(size, micros).toStringAsFixed(1)} MiB/s',
  );
}

Future<Duration> _runPumpTrial({required int size, required int iterations}) async {
  final payload = List<int>.generate(size, (index) => index % 251, growable: false);
  final expectedBytes = size * iterations;
  final receivedAll = Completer<void>();
  var receivedBytes = 0;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((message) {
        if (message is! String || !message.startsWith(_prefix) || !message.endsWith(_suffix)) {
          if (!receivedAll.isCompleted) {
            receivedAll.completeError(StateError('Received an invalid pump message.'));
          }
          return;
        }
        final encodedLength = message.length - _prefix.length - _suffix.length;
        final payloadEnd = message.length - _suffix.length;
        var padding = 0;
        if (encodedLength > 0 && message.codeUnitAt(payloadEnd - 1) == 61) padding++;
        if (encodedLength > 1 && message.codeUnitAt(payloadEnd - 2) == 61) padding++;
        receivedBytes += encodedLength ~/ 4 * 3 - padding;
        if (receivedBytes == expectedBytes && !receivedAll.isCompleted) receivedAll.complete();
      }, onError: receivedAll.completeError);
      return;
    }
    for (var index = 0; index < iterations; index++) {
      request.response.add(payload);
      await request.response.flush();
    }
    await request.response.close();
  });

  final transport = await NativeHttpClientTransport.open(webSocketOutgoingCapacity: 1024);
  final socket = await transport.connect(
    DartHttpClientWebSocketRequest(
      uri: Uri.parse('ws://${server.address.host}:${server.port}/pump'),
    ),
  );
  final response = await transport.sendNative(
    DartHttpClientRequest(
      method: HttpMethod.get,
      uri: Uri.parse('http://${server.address.host}:${server.port}/source'),
    ),
  );
  final pump = (socket as DartHttpClientNativeStreamWebSocket).adoptBase64TextStream(response.body);
  try {
    final stopwatch = Stopwatch()..start();
    pump.resume(prefix: _prefix, suffix: _suffix);
    await receivedAll.future.timeout(const Duration(seconds: 20));
    await pump.pauseAndFlush().timeout(const Duration(seconds: 20));
    stopwatch.stop();
    return stopwatch.elapsed;
  } finally {
    pump.close();
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
