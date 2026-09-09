import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_http_client/dart_http_client.dart';
import 'package:dart_http_core/dart_http_core.dart';
import 'package:dart_http_native_client/dart_http_native_client.dart';

const _samples = 5;

Future<void> main() async {
  await NativeHttpClientRuntime.prewarm();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final serverSubscription = server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    if (request.uri.path == '/leased') {
      final count = int.parse(request.uri.queryParameters['count']!);
      final size = int.parse(request.uri.queryParameters['size']!);
      final payload = Uint8List(size);
      for (var index = 0; index < count; index++) {
        socket.add(payload);
      }
    }
    socket.listen(socket.add);
  });
  final baseUri = Uri.parse('ws://${server.address.host}:${server.port}');
  final native = await NativeHttpClientTransport.open(
    webSocketIncomingCapacity: 1024,
    webSocketOutgoingCapacity: 1024,
  );
  const dart = DartHttpWebSocketClientTransport();

  try {
    stdout.writeln('WebSocket client benchmark (median of ${_samples - 1} measured samples)');
    stdout.writeln('Native runtime is prewarmed; throughput counts outbound payload bytes.');
    await _benchmarkConnections(dart: dart, native: native, uri: baseUri.resolve('/echo'));
    await _benchmarkEcho(
      name: 'text 128 B',
      dart: dart,
      native: native,
      uri: baseUri.resolve('/echo'),
      count: 1000,
      size: 128,
      text: true,
    );
    await _benchmarkEcho(
      name: 'binary copy 960 B',
      dart: dart,
      native: native,
      uri: baseUri.resolve('/echo'),
      count: 512,
      size: 960,
    );
    await _benchmarkEcho(
      name: 'binary copy 64 KiB',
      dart: dart,
      native: native,
      uri: baseUri.resolve('/echo'),
      count: 128,
      size: 64 * 1024,
    );
    await _benchmarkLeased(
      name: 'binary lease 960 B',
      dart: dart,
      native: native,
      baseUri: baseUri,
      count: 512,
      size: 960,
    );
    await _benchmarkLeased(
      name: 'binary lease 64 KiB',
      dart: dart,
      native: native,
      baseUri: baseUri,
      count: 128,
      size: 64 * 1024,
    );
    await _benchmarkLeased(
      name: 'queued lease 960 B',
      dart: dart,
      native: native,
      baseUri: baseUri,
      count: 512,
      size: 960,
      queueNative: true,
    );
    await _benchmarkLeased(
      name: 'queued lease 64 KiB',
      dart: dart,
      native: native,
      baseUri: baseUri,
      count: 128,
      size: 64 * 1024,
      queueNative: true,
    );
  } finally {
    native.close();
    await serverSubscription.cancel();
    await server.close(force: true);
  }
}

Future<void> _benchmarkConnections({
  required DartHttpClientWebSocketTransport dart,
  required DartHttpClientWebSocketTransport native,
  required Uri uri,
}) async {
  final dartSamples = <Duration>[];
  final nativeSamples = <Duration>[];
  for (var sample = 0; sample < _samples; sample++) {
    final dartDuration = await _connectionTrial(dart, uri);
    final nativeDuration = await _connectionTrial(native, uri);
    if (sample > 0) {
      dartSamples.add(dartDuration);
      nativeSamples.add(nativeDuration);
    }
  }
  final dartMicros = _median(dartSamples).inMicroseconds.toDouble();
  final nativeMicros = _median(nativeSamples).inMicroseconds.toDouble();
  _writeResult('connect', dartMicros, nativeMicros, unit: 'us');
}

Future<Duration> _connectionTrial(DartHttpClientWebSocketTransport transport, Uri uri) async {
  final stopwatch = Stopwatch()..start();
  final socket = await transport.connect(DartHttpClientWebSocketRequest(uri: uri));
  stopwatch.stop();
  await socket.close();
  return stopwatch.elapsed;
}

Future<void> _benchmarkEcho({
  required String name,
  required DartHttpClientWebSocketTransport dart,
  required DartHttpClientWebSocketTransport native,
  required Uri uri,
  required int count,
  required int size,
  bool text = false,
}) async {
  final dartSamples = <Duration>[];
  final nativeSamples = <Duration>[];
  for (var sample = 0; sample < _samples; sample++) {
    final dartDuration = await _echoTrial(dart, uri, count: count, size: size, text: text);
    final nativeDuration = await _echoTrial(native, uri, count: count, size: size, text: text);
    if (sample > 0) {
      dartSamples.add(dartDuration);
      nativeSamples.add(nativeDuration);
    }
  }
  _writeThroughput(name, dartSamples, nativeSamples, count: count, size: size);
}

Future<Duration> _echoTrial(
  DartHttpClientWebSocketTransport transport,
  Uri uri, {
  required int count,
  required int size,
  required bool text,
}) async {
  final socket = await transport.connect(DartHttpClientWebSocketRequest(uri: uri));
  final received = Completer<void>();
  var receivedCount = 0;
  final subscription = socket.messages.listen((message) {
    if (text) {
      if (message.kind != WebSocketMessageKind.text || message.text.length != size) {
        received.completeError(StateError('Invalid echoed text message.'));
        return;
      }
    } else {
      final lease = message.takeBinaryLease();
      if (lease.length != size) {
        received.completeError(StateError('Invalid echoed binary message.'));
        lease.close();
        return;
      }
      lease.close();
    }
    receivedCount++;
    if (receivedCount == count && !received.isCompleted) received.complete();
  }, onError: received.completeError);
  final textPayload = text ? 'x' * size : null;
  final binaryPayload = text ? null : Uint8List(size);
  final stopwatch = Stopwatch()..start();
  try {
    for (var index = 0; index < count; index++) {
      if (textPayload != null) {
        await socket.sendText(textPayload);
      } else {
        await socket.sendBinary(binaryPayload!);
      }
    }
    await received.future.timeout(const Duration(seconds: 10));
    stopwatch.stop();
    return stopwatch.elapsed;
  } finally {
    await subscription.cancel();
    await socket.close();
  }
}

Future<void> _benchmarkLeased({
  required String name,
  required DartHttpClientWebSocketTransport dart,
  required DartHttpClientWebSocketTransport native,
  required Uri baseUri,
  required int count,
  required int size,
  bool queueNative = false,
}) async {
  final uri = baseUri.resolve('/leased?count=$count&size=$size');
  final dartSamples = <Duration>[];
  final nativeSamples = <Duration>[];
  for (var sample = 0; sample < _samples; sample++) {
    final dartDuration = await _leasedTrial(dart, uri, count: count, size: size);
    final nativeDuration = await _leasedTrial(
      native,
      uri,
      count: count,
      size: size,
      queued: queueNative,
    );
    if (sample > 0) {
      dartSamples.add(dartDuration);
      nativeSamples.add(nativeDuration);
    }
  }
  _writeThroughput(name, dartSamples, nativeSamples, count: count, size: size);
}

Future<Duration> _leasedTrial(
  DartHttpClientWebSocketTransport transport,
  Uri uri, {
  required int count,
  required int size,
  bool queued = false,
}) async {
  final socket = await transport.connect(DartHttpClientWebSocketRequest(uri: uri));
  final sourceReady = Completer<void>();
  final echoed = Completer<void>();
  final source = <BinaryPayloadLease>[];
  var echoedCount = 0;
  var sending = false;
  final subscription = socket.messages.listen(
    (message) {
      final lease = message.takeBinaryLease();
      if (lease.length != size) {
        lease.close();
        final target = sending ? echoed : sourceReady;
        if (!target.isCompleted) target.completeError(StateError('Invalid leased binary message.'));
        return;
      }
      if (!sending) {
        source.add(lease);
        if (source.length == count && !sourceReady.isCompleted) sourceReady.complete();
        return;
      }
      lease.close();
      echoedCount++;
      if (echoedCount == count && !echoed.isCompleted) echoed.complete();
    },
    onError: (Object error, StackTrace stackTrace) {
      final target = sending ? echoed : sourceReady;
      if (!target.isCompleted) target.completeError(error, stackTrace);
    },
  );
  try {
    await sourceReady.future.timeout(const Duration(seconds: 10));
    sending = true;
    final stopwatch = Stopwatch()..start();
    if (queued) {
      final queue = socket as DartHttpClientQueuedWebSocket;
      for (final lease in source) {
        final byteLease = switch (lease) {
          NativeExchangeBinaryPayloadLease(lease: final value) => value,
          _ => throw StateError('Queued benchmark requires Native Exchange leases.'),
        };
        queue.enqueueByteLease(byteLease);
      }
      await queue.flush();
    } else {
      for (final lease in source) {
        await socket.sendBinaryLease(lease);
      }
    }
    await echoed.future.timeout(const Duration(seconds: 10));
    stopwatch.stop();
    return stopwatch.elapsed;
  } finally {
    for (final lease in source) {
      lease.close();
    }
    await subscription.cancel();
    await socket.close();
  }
}

void _writeThroughput(
  String name,
  List<Duration> dartSamples,
  List<Duration> nativeSamples, {
  required int count,
  required int size,
}) {
  final dart = _median(dartSamples);
  final native = _median(nativeSamples);
  final dartRate = count / (dart.inMicroseconds / Duration.microsecondsPerSecond);
  final nativeRate = count / (native.inMicroseconds / Duration.microsecondsPerSecond);
  final dartMib = dartRate * size / (1024 * 1024);
  final nativeMib = nativeRate * size / (1024 * 1024);
  stdout.writeln(
    '${name.padRight(22)}  '
    'Dart ${dartRate.toStringAsFixed(0).padLeft(7)} msg/s '
    '${dartMib.toStringAsFixed(1).padLeft(7)} MiB/s  '
    'native ${nativeRate.toStringAsFixed(0).padLeft(7)} msg/s '
    '${nativeMib.toStringAsFixed(1).padLeft(7)} MiB/s  '
    '${(nativeRate / dartRate).toStringAsFixed(2)}x',
  );
}

void _writeResult(String name, double dartValue, double nativeValue, {required String unit}) {
  stdout.writeln(
    '${name.padRight(22)}  '
    'Dart ${dartValue.toStringAsFixed(1).padLeft(8)} $unit  '
    'native ${nativeValue.toStringAsFixed(1).padLeft(8)} $unit  '
    '${(dartValue / nativeValue).toStringAsFixed(2)}x',
  );
}

Duration _median(List<Duration> values) {
  values.sort((left, right) => left.compareTo(right));
  return values[values.length ~/ 2];
}
