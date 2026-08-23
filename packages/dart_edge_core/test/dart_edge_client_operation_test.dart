import 'dart:async';

import 'package:dart_edge_core/dart_edge_core.dart';
import 'package:test/test.dart';

void main() {
  const info = DartEdgeClientOperationInfo(
    operationId: 'createItem',
    kind: DartEdgeClientOperationKind.http,
    pathTemplate: '/items',
    method: HttpMethod.post,
  );

  test('tracks a successful started request', () async {
    final handle = startDartEdgeClientRequest<String>(info: info, run: (_) async => 'done');

    expect(handle.state, DartEdgeClientRequestState.pending);
    expect(await handle.future, 'done');
    expect(handle.state, DartEdgeClientRequestState.succeeded);
    expect(handle.endedAt, isNotNull);
    expect(handle.info, same(info));
  });

  test('cancels through the supplied abort trigger', () async {
    final aborted = Completer<void>();
    final handle = startDartEdgeClientRequest<void>(
      info: info,
      run: (abortTrigger) async {
        await abortTrigger;
        aborted.complete();
      },
    );

    handle.cancel();
    await handle.future;

    expect(aborted.isCompleted, isTrue);
    expect(handle.state, DartEdgeClientRequestState.canceled);
    expect(handle.isCanceled, isTrue);
  });

  test('times out through the supplied abort trigger', () async {
    final handle = startDartEdgeClientRequest<void>(
      info: info,
      timeout: Duration.zero,
      run: (abortTrigger) => abortTrigger,
    );

    await handle.future;

    expect(handle.state, DartEdgeClientRequestState.timedOut);
    expect(handle.isCanceled, isFalse);
  });
}
