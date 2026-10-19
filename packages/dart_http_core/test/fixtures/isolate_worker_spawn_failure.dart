// Spawns an isolate worker (or pool, with the `pool` argument) whose handler
// cannot be sent to another isolate, reports the failure, and then returns
// from main. The process only exits if the failed spawn released every port.
import 'dart:isolate';

import 'package:dart_http_core/dart_http_core.dart';

Future<void> main(List<String> args) async {
  final unsendable = ReceivePort()..close();
  Object? handler(Object? request) => unsendable.hashCode;

  try {
    if (args.contains('pool')) {
      await DartHttpIsolateWorkerPool.spawn(handler: handler, size: 2);
    } else {
      await DartHttpIsolateWorker.spawn(handler: handler);
    }
    print('spawned');
  } on Object catch (error) {
    print('spawn failed: ${error.runtimeType}');
  }
}
