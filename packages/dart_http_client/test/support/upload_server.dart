import 'dart:async';
import 'dart:io';

import 'package:stream_channel/stream_channel.dart';

Future<void> hybridMain(StreamChannel<Object?> channel) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  channel.sink.add('http://${server.address.host}:${server.port}');
  server.listen((request) async {
    final response = request.response;
    response.headers
      ..set('access-control-allow-origin', request.headers.value('origin') ?? '*')
      ..set('access-control-allow-credentials', 'true')
      ..set('access-control-allow-methods', 'POST, PATCH, OPTIONS')
      ..set('access-control-allow-headers', 'content-type, authorization')
      ..set('access-control-expose-headers', 'x-received-bytes');
    if (request.method == 'OPTIONS') {
      response.statusCode = 204;
      await response.close();
      return;
    }
    try {
      var count = 0;
      await for (final chunk in request) {
        count += chunk.length;
        if (request.uri.path == '/slow') {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }
      response.headers.set('x-received-bytes', count);
      response.write(count);
      await response.close();
    } on Object {
      // Client cancellation is an expected part of the browser tests.
      try {
        await response.close();
      } on Object {
        /* disconnected */
      }
    }
  });
  await channel.stream.drain<void>();
  await server.close(force: true);
}
