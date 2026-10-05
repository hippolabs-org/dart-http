import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dart_http_server_runtime/dart_http_server_runtime.dart';
import 'package:test/test.dart';

void main() {
  for (final workers in [1, 4]) {
    test('paused Dart audio leaves other requests responsive with $workers I/O workers', () async {
      final server = await _RunningServer.start(workers: workers);
      final audio = await _PausedConnection.open(server.port, '/audio');
      try {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        for (var i = 0; i < 3; i++) {
          expect(await _get(server.port, '/health'), 'ok');
        }
      } finally {
        await audio.close();
        await server.disposed('audio');
        await server.close();
      }
    });
  }

  test('disconnect cancels a Dart producer awaiting its next chunk', () async {
    final server = await _RunningServer.start();
    final audio = await _PausedConnection.open(server.port, '/idle');
    try {
      await audio.close();
      await server.disposed('idle');
      expect(await _get(server.port, '/health'), 'ok');
    } finally {
      await server.close();
    }
  });

  test('a stalled Dart transfer disposes before the client disconnects', () async {
    final server = await _RunningServer.start(stallTimeout: const Duration(milliseconds: 350));
    final audio = await _PausedConnection.open(server.port, '/audio');
    try {
      await server.disposed('audio');
      expect(await _get(server.port, '/health'), 'ok');
    } finally {
      await audio.close();
      await server.close();
    }
  });

  test('a stalled Dart source is canceled without a client disconnect', () async {
    final server = await _RunningServer.start(stallTimeout: const Duration(milliseconds: 350));
    final audio = await _PausedConnection.open(server.port, '/idle');
    try {
      await server.disposed('idle');
      expect(await _get(server.port, '/health'), 'ok');
    } finally {
      await audio.close();
      await server.close();
    }
  });

  test('native reader overload returns 503 and disconnect releases capacity', () async {
    final server = await _RunningServer.start(workers: 4, nativeStreamWorkers: 1);
    final audio = await _PausedConnection.open(server.port, '/native', upload: true);
    try {
      expect(await _nativeEcho(server.port), 503);
      expect(await _get(server.port, '/health'), 'ok');
      await audio.close();
      await _waitForNativeCapacity(server.port);
    } finally {
      await audio.close();
      await server.close();
    }
  });

  test('stalled native source releases its reader without a client disconnect', () async {
    final server = await _RunningServer.start(
      nativeStreamWorkers: 1,
      stallTimeout: const Duration(milliseconds: 350),
    );
    final audio = await _PausedConnection.open(server.port, '/native', upload: true);
    try {
      await _waitForNativeCapacity(server.port);
      expect(await _get(server.port, '/health'), 'ok');
    } finally {
      await audio.close();
      await server.close();
    }
  });

  test('splits large producer chunks without changing their bytes', () async {
    final server = await _RunningServer.start();
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(Uri.http('127.0.0.1:${server.port}', '/large')))
          .close();
      final bytes = await response.expand((chunk) => chunk).toList();
      expect(bytes, List<int>.generate(200000, (i) => i % 256));
    } finally {
      client.close(force: true);
      await server.close();
    }
  });
}

Future<String> _get(int port, String path) async {
  final client = HttpClient();
  try {
    return await (() async {
      final response = await (await client.getUrl(Uri.http('127.0.0.1:$port', path))).close();
      return String.fromCharCodes(await response.expand((chunk) => chunk).toList());
    })().timeout(const Duration(seconds: 2));
  } finally {
    client.close(force: true);
  }
}

Future<int> _nativeEcho(int port) async {
  final client = HttpClient();
  try {
    return await (() async {
      final request = await client.postUrl(Uri.http('127.0.0.1:$port', '/native'));
      request.headers.contentType = ContentType.binary;
      request.contentLength = 4;
      request.add([1, 2, 3, 4]);
      final response = await request.close();
      final bytes = await response.expand((chunk) => chunk).toList();
      if (response.statusCode == 200) expect(bytes, [1, 2, 3, 4]);
      return response.statusCode;
    })().timeout(const Duration(seconds: 2));
  } finally {
    client.close(force: true);
  }
}

Future<void> _waitForNativeCapacity(int port) async {
  for (var i = 0; i < 40; i++) {
    if (await _nativeEcho(port) == 200) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('Native response reader was not released.');
}

final class _PausedConnection {
  _PausedConnection(this.socket, this.subscription);
  final Socket socket;
  final StreamSubscription<List<int>> subscription;

  static Future<_PausedConnection> open(int port, String path, {bool upload = false}) async {
    final socket = await Socket.connect('127.0.0.1', port);
    final receivedBody = Completer<void>();
    final headers = <int>[];
    late StreamSubscription<List<int>> subscription;
    subscription = socket.listen((bytes) {
      headers.addAll(bytes);
      final headerEnd = String.fromCharCodes(headers).indexOf('\r\n\r\n');
      if (headerEnd >= 0 && headers.length > headerEnd + 4 && !receivedBody.isCompleted) {
        if (!String.fromCharCodes(headers).startsWith('HTTP/1.1 200')) {
          receivedBody.completeError(StateError('Expected streaming HTTP 200 response.'));
        } else {
          subscription.pause();
          receivedBody.complete();
        }
      }
    });
    socket.write(
      '${upload ? 'POST' : 'GET'} $path HTTP/1.1\r\nHost: localhost\r\n'
      'Connection: close\r\n${upload ? 'Content-Type: application/octet-stream\r\nContent-Length: 16777216\r\n' : ''}\r\n',
    );
    if (upload) socket.add(Uint8List(64 * 1024));
    await socket.flush();
    try {
      await receivedBody.future.timeout(const Duration(seconds: 5));
      return _PausedConnection(socket, subscription);
    } catch (_) {
      socket.destroy();
      await subscription.cancel();
      rethrow;
    }
  }

  Future<void> close() async {
    socket.destroy();
    await subscription.cancel();
  }
}

final class _RunningServer {
  _RunningServer(this.events);
  final ReceivePort events;
  final ready = Completer<void>();
  final stopped = Completer<void>();
  final Map<String, Completer<void>> disposals = {};
  late final Isolate isolate;
  late final int port;
  late final SendPort commands;

  static Future<_RunningServer> start({
    int workers = 1,
    int nativeStreamWorkers = 64,
    Duration stallTimeout = const Duration(seconds: 10),
  }) async {
    final server = _RunningServer(ReceivePort());
    server.events.listen((dynamic message) {
      final values = message as List<dynamic>;
      switch (values[0]) {
        case 'ready':
          server.port = values[1] as int;
          server.commands = values[2] as SendPort;
          server.ready.complete();
        case 'disposed':
          final completion = server.disposals.putIfAbsent(values[1] as String, Completer<void>.new);
          if (!completion.isCompleted) completion.complete();
        case 'stopped':
          server.stopped.complete();
      }
    });
    // An independent isolate lets the test watchdog and client disconnect run
    // even if a regression blocks the server's Dart event loop.
    server.isolate = await Isolate.spawn(_serve, [
      server.events.sendPort,
      workers,
      nativeStreamWorkers,
      stallTimeout,
    ]);
    await server.ready.future.timeout(const Duration(seconds: 10));
    return server;
  }

  Future<void> disposed(String kind) =>
      disposals.putIfAbsent(kind, Completer<void>.new).future.timeout(const Duration(seconds: 5));

  Future<void> close() async {
    commands.send(null);
    try {
      await stopped.future.timeout(const Duration(seconds: 5));
    } finally {
      events.close();
      isolate.kill(priority: Isolate.immediate);
    }
  }
}

Future<void> _serve(List<Object> args) async {
  final events = args[0] as SendPort;
  final app = DartHttp<void>();
  final idleReleased = Completer<void>();
  app.get('/health', handler: (_) => RawResponse.text(status: 200, body: 'ok'));
  app.get(
    '/audio',
    handler: (_) => BinaryStreamResponse(
      body: _audioChunks(),
      contentType: 'audio/wav',
      contentLength: 512 * 1024 * 1024,
      onDispose: () => events.send(['disposed', 'audio']),
    ),
  );
  app.get(
    '/idle',
    handler: (_) => BinaryStreamResponse(
      body: _idleChunks(idleReleased.future),
      contentType: 'audio/wav',
      onDispose: () {
        idleReleased.complete();
        events.send(['disposed', 'idle']);
      },
    ),
  );
  app.get(
    '/large',
    handler: (_) => BinaryStreamResponse(
      body: Stream.value(Uint8List.fromList(List<int>.generate(200000, (i) => i % 256))),
      contentType: 'application/octet-stream',
      contentLength: 200000,
    ),
  );
  app.post(
    '/native',
    options: const RouteOptions(
      body: RequestBody.binaryStream(contentType: 'application/octet-stream'),
    ),
    handler: (ctx) => NativeBinaryStreamResponse(
      body: ctx.req.nativeBodyStream!.takeNative(),
      contentType: 'application/octet-stream',
      contentLength: ctx.req.nativeBodyStream!.contentLength,
    ),
  );
  final server = await app.listen(
    port: 0,
    workers: args[1] as int,
    nativeStreamWorkers: args[2] as int,
    streamStallTimeout: args[3] as Duration,
  );
  final commands = ReceivePort();
  events.send(['ready', server.port, commands.sendPort]);
  await commands.first;
  await server.close();
  commands.close();
  events.send(['stopped']);
}

Stream<List<int>> _audioChunks() async* {
  final chunk = Uint8List(256 * 1024);
  for (var i = 0; i < 2048; i++) {
    yield chunk;
  }
}

Stream<List<int>> _idleChunks(Future<void> released) async* {
  yield [1];
  await released;
}
