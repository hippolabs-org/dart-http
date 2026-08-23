import 'dart:async';

import 'package:dart_http_core/dart_http_core.dart';
import 'package:test/test.dart';

void main() {
  const info = DartHttpClientOperationInfo(
    operationId: 'createItem',
    kind: DartHttpClientOperationKind.http,
    pathTemplate: '/items',
    method: HttpMethod.post,
  );

  test('tracks a successful started request', () async {
    final handle = startDartHttpClientRequest<String>(info: info, run: (_) async => 'done');

    expect(handle.state, DartHttpClientRequestState.pending);
    expect(await handle.future, 'done');
    expect(handle.state, DartHttpClientRequestState.succeeded);
    expect(handle.endedAt, isNotNull);
    expect(handle.info, same(info));
  });

  test('cancels through the supplied abort trigger', () async {
    final aborted = Completer<void>();
    final handle = startDartHttpClientRequest<void>(
      info: info,
      run: (abortTrigger) async {
        await abortTrigger;
        aborted.complete();
      },
    );

    handle.cancel();
    await handle.future;

    expect(aborted.isCompleted, isTrue);
    expect(handle.state, DartHttpClientRequestState.canceled);
    expect(handle.isCanceled, isTrue);
  });

  test('times out through the supplied abort trigger', () async {
    final handle = startDartHttpClientRequest<void>(
      info: info,
      timeout: Duration.zero,
      run: (abortTrigger) => abortTrigger,
    );

    await handle.future;

    expect(handle.state, DartHttpClientRequestState.timedOut);
    expect(handle.isCanceled, isFalse);
  });
}
