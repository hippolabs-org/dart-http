import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_http_core/dart_http_core.dart';
import 'package:dart_http_native_client/dart_http_native_client.dart';

const _chunkBytes = 64 * 1024;
const _requestBytes = 4 * 1024 * 1024;
const _throughputRequests = 256;

Future<void> main() async {
  await NativeHttpClientRuntime.prewarm();
  final firstByteSamples = <Duration>[];
  for (var sample = 0; sample < 5; sample++) {
    firstByteSamples.add(await _measureFirstByte());
  }

  final throughputSamples = <double>[];
  for (var sample = 0; sample < 3; sample++) {
    throughputSamples.add(await _measureThroughput());
  }

  firstByteSamples.sort();
  throughputSamples.sort();
  stdout.writeln('Dart request body stream benchmark');
  stdout.writeln(
    'median first byte: '
    '${firstByteSamples[firstByteSamples.length ~/ 2].inMicroseconds / 1000} ms',
  );
  stdout.writeln(
    'median throughput: '
    '${throughputSamples[throughputSamples.length ~/ 2].toStringAsFixed(1)} MiB/s',
  );
}

Future<Duration> _measureFirstByte() async {
  final firstByte = Completer<Duration>();
  final stopwatch = Stopwatch();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final subscription = server.listen((request) async {
    var received = 0;
    await for (final chunk in request) {
      received += chunk.length;
      if (!firstByte.isCompleted) firstByte.complete(stopwatch.elapsed);
    }
    request.response.write(received);
    await request.response.close();
  });
  final transport = await NativeHttpClientTransport.open();
  try {
    stopwatch.start();
    final responseFuture = transport.send(
      DartHttpClientRequest(
        method: HttpMethod.post,
        uri: Uri.parse('http://${server.address.host}:${server.port}/upload'),
        bodyStream: _chunks(delay: const Duration(milliseconds: 1)),
        bodyStreamLength: _requestBytes,
      ),
    );
    final elapsed = await firstByte.future.timeout(const Duration(seconds: 5));
    final response = await responseFuture.timeout(const Duration(seconds: 5));
    if (response.body != '$_requestBytes') {
      throw StateError('Incomplete benchmark upload.');
    }
    return elapsed;
  } finally {
    transport.close();
    await subscription.cancel();
    await server.close(force: true);
  }
}

Future<double> _measureThroughput() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final subscription = server.listen((request) async {
    var received = 0;
    await for (final chunk in request) {
      received += chunk.length;
    }
    request.response.write(received);
    await request.response.close();
  });
  final transport = await NativeHttpClientTransport.open();
  try {
    final stopwatch = Stopwatch()..start();
    for (var request = 0; request < _throughputRequests; request++) {
      final response = await transport.send(
        DartHttpClientRequest(
          method: HttpMethod.post,
          uri: Uri.parse('http://${server.address.host}:${server.port}/upload'),
          bodyStream: _chunks(),
          bodyStreamLength: _requestBytes,
        ),
      );
      if (response.body != '$_requestBytes') {
        throw StateError('Incomplete benchmark upload.');
      }
    }
    stopwatch.stop();
    final mebibytes = _throughputRequests * _requestBytes / (1024 * 1024);
    return mebibytes / (stopwatch.elapsedMicroseconds / Duration.microsecondsPerSecond);
  } finally {
    transport.close();
    await subscription.cancel();
    await server.close(force: true);
  }
}

Stream<List<int>> _chunks({Duration? delay}) async* {
  final chunk = Uint8List(_chunkBytes);
  for (var sent = 0; sent < _requestBytes; sent += chunk.length) {
    if (delay != null) await Future<void>.delayed(delay);
    yield chunk;
  }
}
