import 'dart:convert';

import 'package:dart_edge_http_server/dart_edge_http_server.dart';

Future<void> main() async {
  final app = DartEdge<void>(services: () {});
  final api = app.router('/api');

  api.get('/health', handler: (_) => const {'status': 'ok'});
  api.webtransport(
    '/events',
    options: const WebTransportOptions(
      operationId: 'connectEvents',
      summary: 'Open a WebTransport datagram echo session.',
    ),
    onConnect: (transport) async {
      await transport.sendDatagram(utf8.encode('connected'));

      await for (final datagram in transport.datagrams.datagrams()) {
        await transport.sendDatagram(datagram);
      }
    },
  );

  final server = await app.listen(port: 8080, workers: 1);
  print('Dart Edge listening on http://${server.host}:${server.port}');
  print('WebTransport route: https://${server.host}:${server.port}/api/events');
}
