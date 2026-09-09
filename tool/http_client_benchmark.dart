import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_http_client/dart_http_client.dart';
import 'package:dart_http_core/dart_http_core.dart';
import 'package:dart_http_native_client/dart_http_native_client.dart';

const _smallRequestCount = 1000;
const _largeRequestCount = 64;
const _largeBodyBytes = 1024 * 1024;
const _streamRequestCount = 8;
const _streamBodyBytes = 16 * 1024 * 1024;
const _streamChunkBytes = 64 * 1024;
const _uploadRequestCount = 32;
const _uploadBodyBytes = 4 * 1024 * 1024;
const _uploadChunkBytes = 64 * 1024;

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1 ||
      !const {'dart', 'native', 'native-prewarmed'}.contains(arguments.single)) {
    stderr.writeln(
      'Usage: dart run tool/http_client_benchmark.dart '
      '<dart|native|native-prewarmed>',
    );
    exitCode = 64;
    return;
  }

  final backend = arguments.single;
  final usesNative = backend != 'dart';
  final smallResponse = utf8.encode('{"ok":true,"payload":"${'x' * 960}"}');
  final responseChunk = Uint8List(_streamChunkBytes);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final serverSubscription = server.listen((request) async {
    switch (request.uri.path) {
      case '/small':
        request.response
          ..headers.contentType = ContentType.json
          ..contentLength = smallResponse.length
          ..add(smallResponse);
      case '/large':
        request.response
          ..contentLength = _largeBodyBytes
          ..add(Uint8List(_largeBodyBytes));
      case '/stream':
        request.response.contentLength = _streamBodyBytes;
        for (var sent = 0; sent < _streamBodyBytes; sent += responseChunk.length) {
          request.response.add(responseChunk);
        }
      case '/upload':
        var received = 0;
        await for (final chunk in request) {
          received += chunk.length;
        }
        request.response.write(received);
      default:
        request.response.statusCode = HttpStatus.notFound;
    }
    await request.response.close();
  });

  final baseUri = Uri.parse('http://${server.address.host}:${server.port}');
  final rssBeforeClient = ProcessInfo.currentRss;
  final threadsBeforeClient = await _threadCount();
  final cpuBefore = await _cpuSeconds();
  final totalStopwatch = Stopwatch()..start();

  Duration? prewarmElapsed;
  if (backend == 'native-prewarmed') {
    final stopwatch = Stopwatch()..start();
    await NativeHttpClientRuntime.prewarm();
    stopwatch.stop();
    prewarmElapsed = stopwatch.elapsed;
  }

  late final HttpClientTransport transport;
  late final void Function() closeTransport;
  final openStopwatch = Stopwatch()..start();
  if (usesNative) {
    final native = await NativeHttpClientTransport.open();
    transport = native;
    closeTransport = native.close;
  } else {
    final dart = DartHttpClientTransport();
    transport = dart;
    closeTransport = dart.close;
  }
  openStopwatch.stop();
  final firstRequestStopwatch = Stopwatch()..start();
  await _sendBuffered(transport, baseUri.resolve('/small'));
  firstRequestStopwatch.stop();

  final warmClientOpenStopwatch = Stopwatch()..start();
  if (usesNative) {
    final warmClient = await NativeHttpClientTransport.open();
    warmClient.close();
  } else {
    final warmClient = DartHttpClientTransport();
    warmClient.close();
  }
  warmClientOpenStopwatch.stop();

  for (var index = 0; index < 50; index++) {
    await _sendBuffered(transport, baseUri.resolve('/small'));
  }

  final measurements = <String, Object?>{};
  measurements['smallSequential'] = await _measure(
    operations: _smallRequestCount,
    action: () async {
      for (var index = 0; index < _smallRequestCount; index++) {
        await _sendBuffered(transport, baseUri.resolve('/small'));
      }
    },
  );
  measurements['smallConcurrent10'] = await _measure(
    operations: _smallRequestCount,
    action: () => _runConcurrent(
      concurrency: 10,
      operations: _smallRequestCount,
      action: () => _sendBuffered(transport, baseUri.resolve('/small')),
    ),
  );
  measurements['smallConcurrent50'] = await _measure(
    operations: _smallRequestCount,
    action: () => _runConcurrent(
      concurrency: 50,
      operations: _smallRequestCount,
      action: () => _sendBuffered(transport, baseUri.resolve('/small')),
    ),
  );
  measurements['largeBuffered'] = await _measure(
    operations: _largeRequestCount,
    bytes: _largeRequestCount * _largeBodyBytes,
    action: () async {
      for (var index = 0; index < _largeRequestCount; index++) {
        final response = await _sendBuffered(transport, baseUri.resolve('/large'));
        if (response.bodyBytes.length != _largeBodyBytes) {
          throw StateError('Incomplete buffered response.');
        }
      }
    },
  );
  final uploadChunk = Uint8List(_uploadChunkBytes);
  measurements['streamedUpload'] = await _measure(
    operations: _uploadRequestCount,
    bytes: _uploadRequestCount * _uploadBodyBytes,
    action: () async {
      for (var index = 0; index < _uploadRequestCount; index++) {
        final response = await transport.send(
          DartHttpClientRequest(
            method: HttpMethod.post,
            uri: baseUri.resolve('/upload'),
            bodyStream: _repeatedChunks(uploadChunk, totalBytes: _uploadBodyBytes),
            bodyStreamLength: _uploadBodyBytes,
          ),
        );
        if (response.body != '$_uploadBodyBytes') {
          throw StateError('Incomplete streamed upload.');
        }
      }
    },
  );
  if (transport case final NativeHttpClientTransport nativeTransport) {
    measurements['largeBufferedLeased'] = await _measure(
      operations: _largeRequestCount,
      bytes: _largeRequestCount * _largeBodyBytes,
      action: () async {
        for (var index = 0; index < _largeRequestCount; index++) {
          final response = await nativeTransport.sendLeased(
            DartHttpClientRequest(method: HttpMethod.get, uri: baseUri.resolve('/large')),
          );
          try {
            if (response.body.length != _largeBodyBytes) {
              throw StateError('Incomplete leased response.');
            }
          } finally {
            response.close();
          }
        }
      },
    );
  }
  var streamChunkCount = 0;
  final streamingMeasurement = await _measure(
    operations: _streamRequestCount,
    bytes: _streamRequestCount * _streamBodyBytes,
    action: () async {
      for (var index = 0; index < _streamRequestCount; index++) {
        var received = 0;
        final request = DartHttpClientRequest(
          method: HttpMethod.get,
          uri: baseUri.resolve('/stream'),
        );
        if (transport case final NativeHttpClientTransport nativeTransport) {
          final response = await nativeTransport.sendLeasedStream(request);
          await for (final lease in response.bodyStream) {
            received += lease.length;
            streamChunkCount++;
            lease.close();
          }
        } else {
          final response = await transport.sendStream(request);
          await for (final chunk in response.bodyStream) {
            received += chunk.length;
            streamChunkCount++;
          }
        }
        if (received != _streamBodyBytes) throw StateError('Incomplete streamed response.');
      }
    },
  );
  streamingMeasurement['chunkCount'] = streamChunkCount;
  streamingMeasurement['averageChunkBytes'] = streamChunkCount == 0
      ? null
      : _streamRequestCount * _streamBodyBytes / streamChunkCount;
  measurements['sustainedStreaming'] = streamingMeasurement;

  totalStopwatch.stop();
  final cpuAfter = await _cpuSeconds();
  final result = <String, Object?>{
    'backend': backend,
    'dartVersion': Platform.version.split(' ').first,
    'logicalProcessors': Platform.numberOfProcessors,
    'coldOpenAndFirstRequestMs': _milliseconds(
      openStopwatch.elapsed + firstRequestStopwatch.elapsed,
    ),
    'coldClientOpenMs': _milliseconds(openStopwatch.elapsed),
    'coldFirstRequestMs': _milliseconds(firstRequestStopwatch.elapsed),
    'warmSecondClientOpenMs': _milliseconds(warmClientOpenStopwatch.elapsed),
    if (prewarmElapsed != null) 'prewarmMs': _milliseconds(prewarmElapsed),
    'rssBeforeClientMiB': _mib(rssBeforeClient),
    'rssAfterBenchmarkMiB': _mib(ProcessInfo.currentRss),
    'threadsBeforeClient': threadsBeforeClient,
    'threadsAfterBenchmark': await _threadCount(),
    'totalWallSeconds': _seconds(totalStopwatch.elapsed),
    'totalCpuSeconds': cpuAfter == null || cpuBefore == null ? null : cpuAfter - cpuBefore,
    'measurements': measurements,
  };

  closeTransport();
  await serverSubscription.cancel();
  await server.close(force: true);
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));
}

Future<DartHttpClientResponse> _sendBuffered(HttpClientTransport transport, Uri uri) =>
    transport.send(DartHttpClientRequest(method: HttpMethod.get, uri: uri));

Stream<List<int>> _repeatedChunks(Uint8List chunk, {required int totalBytes}) async* {
  for (var sent = 0; sent < totalBytes; sent += chunk.length) {
    yield chunk;
  }
}

Future<void> _runConcurrent({
  required int concurrency,
  required int operations,
  required Future<void> Function() action,
}) => Future.wait([
  for (var worker = 0; worker < concurrency; worker++)
    () async {
      for (var index = worker; index < operations; index += concurrency) {
        await action();
      }
    }(),
]);

Future<Map<String, Object?>> _measure({
  required int operations,
  required Future<void> Function() action,
  int? bytes,
}) async {
  final rssAtStart = ProcessInfo.currentRss;
  var peakRss = rssAtStart;
  Object? failure;
  final cpuBefore = await _cpuSeconds();
  final sampler = Timer.periodic(const Duration(milliseconds: 5), (_) {
    peakRss = max(peakRss, ProcessInfo.currentRss);
  });
  final stopwatch = Stopwatch()..start();
  try {
    await action().timeout(const Duration(seconds: 5));
  } catch (error) {
    failure = error;
  } finally {
    stopwatch.stop();
    sampler.cancel();
  }
  final cpuAfter = await _cpuSeconds();
  final seconds = stopwatch.elapsedMicroseconds / Duration.microsecondsPerSecond;
  final cpuSeconds = cpuBefore == null || cpuAfter == null ? null : cpuAfter - cpuBefore;
  return {
    if (failure != null) 'failure': failure.toString(),
    'wallMs': _milliseconds(stopwatch.elapsed),
    'operationsPerSecond': operations / seconds,
    if (bytes != null) 'MiBPerSecond': bytes / (1024 * 1024) / seconds,
    'cpuSeconds': cpuSeconds,
    'cpuPercentOfOneCore': cpuSeconds == null ? null : cpuSeconds / seconds * 100,
    'rssAtStartMiB': _mib(rssAtStart),
    'peakRssMiB': _mib(peakRss),
    'peakRssDeltaMiB': _mib(peakRss - rssAtStart),
  };
}

Future<int?> _threadCount() async {
  if (!Platform.isMacOS && !Platform.isLinux) return null;
  final arguments = Platform.isMacOS
      ? ['-M', pid.toString()]
      : ['-o', 'nlwp=', '-p', pid.toString()];
  final result = await Process.run('ps', arguments);
  if (result.exitCode != 0) return null;
  if (Platform.isLinux) return int.tryParse((result.stdout as String).trim());
  final lines = const LineSplitter().convert(result.stdout as String);
  return max(0, lines.length - 1);
}

Future<double?> _cpuSeconds() async {
  if (!Platform.isMacOS && !Platform.isLinux) return null;
  final result = await Process.run('ps', ['-o', 'time=', '-p', pid.toString()]);
  if (result.exitCode != 0) return null;
  final parts = (result.stdout as String).trim().split(':').map(double.parse).toList();
  if (parts.length == 2) return parts[0] * 60 + parts[1];
  if (parts.length == 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
  return null;
}

double _milliseconds(Duration value) => value.inMicroseconds / 1000;
double _seconds(Duration value) => value.inMicroseconds / Duration.microsecondsPerSecond;
double _mib(int bytes) => bytes / (1024 * 1024);
