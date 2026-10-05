import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dart_http_server_runtime/dart_http_server_runtime.dart';
import 'package:test/test.dart';

void main() {
  test(
    'paused inbound frames leave HTTP responsive, then drain without a long Dart stall',
    () async {
      final server = await _Server.start();
      final peer = await _PausedPeer.open(server.port, '/inbound');
      try {
        peer.socket.add(
          Uint8List.fromList(
            List<int>.generate(60000 * 7, (i) => [0x82, 0x81, 1, 2, 3, 4, 1][i % 7]),
          ),
        );
        await peer.socket.flush();
        for (var i = 0; i < 5; i++) {
          expect((await _get(server.port))['received'], 0);
        }
        await _get(server.port, '/resume');
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        Map<String, dynamic> state;
        do {
          state = await _get(server.port);
          if (state['received'] == 60000) break;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        } while (DateTime.now().isBefore(deadline));
        expect(state['received'], 60000);
        expect(state['maxGapMs'], lessThan(500));
      } finally {
        await peer.close();
        await server.close();
      }
    },
  );

  test('a stalled WebSocket write leaves reads and HTTP live and expires independently', () async {
    final server = await _Server.start();
    final peer = await _PausedPeer.open(server.port, '/outbound');
    try {
      // The peer reads only the HTTP handshake. Its unread audio must stop
      // the producer instead of accumulating the entire 32 MiB in Rust.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      peer.sendText('while-stalled');
      final deadline = DateTime.now().add(const Duration(seconds: 4));
      Map<String, dynamic> state;
      do {
        state = await _get(server.port);
        if (state['received'] == 1 && state['writeStopped'] == true) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      } while (DateTime.now().isBefore(deadline));
      expect(state['received'], 1);
      expect(state['writeStopped'], isTrue);
      expect(state['sent'], lessThan(512));
    } finally {
      await peer.close();
      await server.close();
    }
  });
}

Future<Map<String, dynamic>> _get(int port, [String path = '/health']) async {
  final client = HttpClient();
  try {
    return await (() async {
      final response = await (await client.getUrl(Uri.http('127.0.0.1:$port', path))).close();
      expect(response.statusCode, 200);
      return jsonDecode(await utf8.decoder.bind(response).join()) as Map<String, dynamic>;
    })().timeout(const Duration(seconds: 1));
  } finally {
    client.close(force: true);
  }
}

final class _Server {
  _Server(this.port, this.isolate, this.commands, this.events, this.subscription, this.stopped);
  final int port;
  final Isolate isolate;
  final SendPort commands;
  final ReceivePort events;
  final StreamSubscription<dynamic> subscription;
  final Completer<void> stopped;

  static Future<_Server> start() async {
    final events = ReceivePort();
    final started = Completer<List<dynamic>>();
    final stopped = Completer<void>();
    final subscription = events.listen((dynamic message) {
      if (message is List) started.complete(message);
      if (message == 'stopped') stopped.complete();
    });
    final isolate = await Isolate.spawn(_serve, events.sendPort);
    final startup = await started.future.timeout(const Duration(seconds: 10));
    return _Server(
      startup[0] as int,
      isolate,
      startup[1] as SendPort,
      events,
      subscription,
      stopped,
    );
  }

  Future<void> close() async {
    commands.send('stop');
    try {
      await stopped.future.timeout(const Duration(seconds: 5));
    } finally {
      isolate.kill(priority: Isolate.immediate);
      await subscription.cancel();
      events.close();
    }
  }
}

Future<void> _serve(SendPort events) async {
  final commands = ReceivePort();
  var received = 0;
  var sent = 0;
  var writeStopped = false;
  var maxGapMs = 0.0;
  var lastTick = DateTime.now();
  final timer = Timer.periodic(const Duration(milliseconds: 5), (_) {
    final now = DateTime.now();
    final gap = now.difference(lastTick).inMicroseconds / 1000;
    if (gap > maxGapMs) maxGapMs = gap;
    lastTick = now;
  });
  StreamSubscription<WebSocketMessage>? input;
  Map<String, Object> status() => {
    'received': received,
    'sent': sent,
    'writeStopped': writeStopped,
    'maxGapMs': maxGapMs,
  };
  final app = DartHttp<void>();
  app.get('/health', handler: (_) => status());
  app.get(
    '/resume',
    handler: (_) {
      input?.resume();
      return status();
    },
  );
  app.websocket(
    '/inbound',
    options: const WebSocketOptions(maxPendingMessages: 4, maxPendingBytes: 65536),
    onConnect: (socket) async {
      final done = Completer<void>();
      input = socket.messages.frames().listen((frame) {
        received++;
        frame.close();
      }, onDone: done.complete);
      input!.pause();
      maxGapMs = 0;
      lastTick = DateTime.now();
      await done.future;
    },
  );
  app.websocket(
    '/outbound',
    onConnect: (socket) async {
      final inbound = socket.messages.frames().listen((frame) {
        received++;
        frame.close();
      });
      try {
        final bytes = Uint8List(64 * 1024);
        for (var i = 0; i < 512; i++) {
          await socket.sendBinary(bytes);
          sent++;
        }
      } on StateError {
        writeStopped = true;
      } finally {
        await inbound.cancel();
      }
    },
  );
  final server = await app.listen(
    port: 0,
    workers: 1,
    webSocketWriteStallTimeout: const Duration(milliseconds: 600),
  );
  events.send([server.port, commands.sendPort]);
  await commands.first;
  timer.cancel();
  await server.close();
  commands.close();
  events.send('stopped');
}

final class _PausedPeer {
  _PausedPeer(this.socket, this.subscription);
  final Socket socket;
  final StreamSubscription<Uint8List> subscription;

  static Future<_PausedPeer> open(int port, String path) async {
    final socket = await Socket.connect('127.0.0.1', port);
    final ready = Completer<void>();
    final headers = StringBuffer();
    late final StreamSubscription<Uint8List> subscription;
    subscription = socket.listen((bytes) {
      headers.write(String.fromCharCodes(bytes));
      if (headers.toString().contains('\r\n\r\n')) {
        expect(headers.toString(), startsWith('HTTP/1.1 101'));
        subscription.pause();
        ready.complete();
      }
    });
    socket.write(
      'GET $path HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n',
    );
    await socket.flush();
    await ready.future.timeout(const Duration(seconds: 3));
    return _PausedPeer(socket, subscription);
  }

  void sendText(String text) {
    final bytes = utf8.encode(text);
    const mask = [1, 2, 3, 4];
    socket.add([
      0x81,
      0x80 | bytes.length,
      ...mask,
      for (var i = 0; i < bytes.length; i++) bytes[i] ^ mask[i % 4],
    ]);
  }

  Future<void> close() async {
    socket.destroy();
    await subscription.cancel();
  }
}
