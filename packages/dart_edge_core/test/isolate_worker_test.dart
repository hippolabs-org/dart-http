import 'dart:async';
import 'dart:isolate';

import 'package:dart_edge_core/dart_edge_core.dart';
import 'package:test/test.dart';

void main() {
  test('returns typed request results', () async {
    final worker = await DartEdgeIsolateWorker.spawn(
      handler: _echoLength,
      debugName: 'test-worker',
    );
    addTearDown(worker.close);

    final length = await worker.request<int>('hello');

    expect(length, 5);
  });

  test('propagates worker handler errors', () async {
    final worker = await DartEdgeIsolateWorker.spawn(
      handler: _throwRequest,
      debugName: 'test-worker',
    );
    addTearDown(worker.close);

    await expectLater(worker.request<void>('fail'), throwsA(isA<RemoteError>()));
  });

  test('rejects requests beyond max pending limit', () async {
    final worker = await DartEdgeIsolateWorker.spawn(
      handler: _delayedEcho,
      debugName: 'test-worker',
      maxPendingRequests: 1,
    );
    addTearDown(worker.close);

    final pending = worker.request<String>('first');
    await expectLater(worker.request<String>('second'), throwsA(isA<StateError>()));
    expect(await pending, 'first');
  });

  test('times out pending requests', () async {
    final worker = await DartEdgeIsolateWorker.spawn(
      handler: _delayedEcho,
      debugName: 'test-worker',
      defaultTimeout: const Duration(milliseconds: 10),
    );
    addTearDown(worker.close);

    await expectLater(worker.request<String>('slow'), throwsA(isA<TimeoutException>()));
  });

  test('rejects requests after close', () async {
    final worker = await DartEdgeIsolateWorker.spawn(
      handler: _echoLength,
      debugName: 'test-worker',
    );

    await worker.close();

    await expectLater(worker.request<int>('hello'), throwsA(isA<StateError>()));
  });

  test('worker pool handles concurrent requests', () async {
    final pool = await DartEdgeIsolateWorkerPool.spawn(
      handler: _delayedEcho,
      debugName: 'test-worker-pool',
      size: 2,
    );
    addTearDown(pool.close);

    final results = await Future.wait([
      pool.request<String>('first'),
      pool.request<String>('second'),
    ]);

    expect(results, ['first', 'second']);
  });

  test('worker pool rejects requests after close', () async {
    final pool = await DartEdgeIsolateWorkerPool.spawn(
      handler: _echoLength,
      debugName: 'test-worker-pool',
      size: 2,
    );

    await pool.close();

    await expectLater(pool.request<int>('hello'), throwsA(isA<StateError>()));
  });
}

int _echoLength(Object? request) => (request as String).length;

Never _throwRequest(Object? _) => throw StateError('worker failure');

Future<String> _delayedEcho(Object? request) async {
  await Future<void>.delayed(const Duration(milliseconds: 50));
  return request as String;
}
