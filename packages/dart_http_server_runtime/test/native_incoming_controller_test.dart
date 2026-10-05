import 'dart:async';
import 'dart:collection';

import 'package:dart_http_server_runtime/src/native/native_incoming_controller.dart';
import 'package:test/test.dart';

void main() {
  test('does not pull while paused and drains final values after resume', () async {
    final pending = Queue<int>.of([1, 2, 3]);
    var pulls = 0;
    var cancelled = false;
    final controller = NativeIncomingController<int>(
      take: () {
        pulls++;
        return pending.isEmpty ? null : pending.removeFirst();
      },
      discard: (_) {},
      cancel: () => cancelled = true,
    );
    final values = <int>[];
    final done = Completer<void>();
    final subscription = controller.stream.listen(values.add, onDone: done.complete);
    subscription.pause();
    controller.wake();
    final closed = controller.close();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(pulls, 0);
    subscription.resume();
    await done.future.timeout(const Duration(seconds: 1));
    await closed;
    expect(values, [1, 2, 3]);
    expect(cancelled, isTrue);
  });

  test('dispose releases queued and copied payloads without a listener', () async {
    final pending = Queue<int>.of([1, 2]);
    final discarded = <int>[];
    var released = 0;
    final controller = NativeIncomingController<int>(
      take: () => pending.isEmpty ? null : pending.removeFirst(),
      discard: discarded.add,
      cancel: () {},
    );
    controller.holdRelease(() => released++);
    controller.dispose();
    controller.dispose();
    await controller.close();
    expect(discarded, [1, 2]);
    expect(released, 1);
  });
}
