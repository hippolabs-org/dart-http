import 'dart:async';
import 'dart:isolate';

typedef DartHttpIsolateRequestHandler = FutureOr<Object?> Function(Object? request);

/// Selection strategy used by [DartHttpIsolateWorkerPool].
enum DartHttpIsolateWorkerPoolStrategy {
  /// Sends requests to workers in a fixed rotating order.
  roundRobin,

  /// Sends each request to the worker with the smallest pending queue.
  leastPending,
}

final class DartHttpIsolateWorker {
  DartHttpIsolateWorker._({
    required this.debugName,
    required this.maxPendingRequests,
    required this.defaultTimeout,
    required this._isolate,
    required this._sendPort,
    required ReceivePort receivePort,
    required ReceivePort errorPort,
    required ReceivePort exitPort,
  }) : _receivePort = receivePort,
       _errorPort = errorPort,
       _exitPort = exitPort {
    _subscription = receivePort.listen(_handleResponse);
    _errorSubscription = errorPort.listen(_handleWorkerError);
    _exitSubscription = exitPort.listen(_handleWorkerExit);
  }

  final String debugName;
  final int? maxPendingRequests;
  final Duration? defaultTimeout;

  final Isolate _isolate;
  final SendPort _sendPort;
  final ReceivePort _receivePort;
  final ReceivePort _errorPort;
  final ReceivePort _exitPort;
  late final StreamSubscription<Object?> _subscription;
  late final StreamSubscription<Object?> _errorSubscription;
  late final StreamSubscription<Object?> _exitSubscription;
  final _pending = <int, _PendingRequest>{};
  var _nextId = 0;
  var _closed = false;
  var _failed = false;

  int get pendingRequestCount => _pending.length;

  static Future<DartHttpIsolateWorker> spawn({
    required DartHttpIsolateRequestHandler handler,
    String debugName = 'DartHttpIsolateWorker',
    int? maxPendingRequests,
    Duration? defaultTimeout,
  }) async {
    if (maxPendingRequests case final value? when value < 1) {
      throw ArgumentError.value(
        maxPendingRequests,
        'maxPendingRequests',
        'maxPendingRequests must be at least 1.',
      );
    }

    final readyPort = ReceivePort();
    final responsePort = ReceivePort();
    final errorPort = ReceivePort();
    final exitPort = ReceivePort();
    final isolate = await Isolate.spawn(
      _workerMain,
      _WorkerStartMessage(
        readyPort: readyPort.sendPort,
        responsePort: responsePort.sendPort,
        handler: handler,
      ),
      debugName: debugName,
      errorsAreFatal: true,
      onError: errorPort.sendPort,
      onExit: exitPort.sendPort,
    );
    final sendPort = await readyPort.first as SendPort;
    readyPort.close();

    return DartHttpIsolateWorker._(
      debugName: debugName,
      maxPendingRequests: maxPendingRequests,
      defaultTimeout: defaultTimeout,
      isolate: isolate,
      sendPort: sendPort,
      receivePort: responsePort,
      errorPort: errorPort,
      exitPort: exitPort,
    );
  }

  Future<T> request<T>(Object? request, {Duration? timeout}) async {
    if (_closed) {
      throw StateError('$debugName is closed.');
    }
    if (_failed) {
      throw StateError('$debugName has failed.');
    }
    final maxPending = maxPendingRequests;
    if (maxPending != null && _pending.length >= maxPending) {
      throw StateError('$debugName request queue is full.');
    }

    final id = _nextId++;
    final completer = Completer<Object?>();
    Timer? timer;
    final effectiveTimeout = timeout ?? defaultTimeout;
    if (effectiveTimeout != null) {
      timer = Timer(effectiveTimeout, () {
        final pending = _pending.remove(id);
        if (pending == null || pending.completer.isCompleted) {
          return;
        }
        pending.completer.completeError(
          TimeoutException('$debugName request timed out.', effectiveTimeout),
        );
      });
    }

    _pending[id] = _PendingRequest(completer: completer, timer: timer);
    _sendPort.send(_WorkerRequest(id: id, payload: request));
    return await completer.future as T;
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _sendPort.send(const _WorkerCloseMessage());
    await _subscription.cancel();
    await _errorSubscription.cancel();
    await _exitSubscription.cancel();
    _receivePort.close();
    _errorPort.close();
    _exitPort.close();
    _isolate.kill(priority: Isolate.immediate);
    _failPending(StateError('$debugName is closed.'));
  }

  void _handleResponse(Object? message) {
    final response = message as _WorkerResponse;
    final pending = _pending.remove(response.id);
    if (pending == null || pending.completer.isCompleted) {
      return;
    }
    pending.timer?.cancel();
    if (response.success) {
      pending.completer.complete(response.payload);
    } else {
      pending.completer.completeError(
        RemoteError(response.error ?? '$debugName request failed.', response.stackTrace ?? ''),
      );
    }
  }

  void _handleWorkerError(Object? message) {
    _failed = true;
    final values = message as List<Object?>;
    _failPending(
      RemoteError(
        values.isEmpty ? '$debugName failed.' : values[0].toString(),
        values.length < 2 ? '' : values[1].toString(),
      ),
    );
  }

  void _handleWorkerExit(Object? _) {
    if (_closed) {
      return;
    }
    _failed = true;
    _failPending(StateError('$debugName exited.'));
  }

  void _failPending(Object error) {
    final pendingRequests = List<_PendingRequest>.of(_pending.values);
    _pending.clear();
    for (final pending in pendingRequests) {
      pending.timer?.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(error);
      }
    }
  }
}

/// Pool of long-lived isolate workers for repeated native-backed requests.
final class DartHttpIsolateWorkerPool {
  DartHttpIsolateWorkerPool._(
    this._workers, {
    required this.debugName,
    required this.size,
    required this.strategy,
  });

  final String debugName;
  final int size;
  final DartHttpIsolateWorkerPoolStrategy strategy;
  final List<DartHttpIsolateWorker> _workers;
  var _nextWorker = 0;
  var _closed = false;

  static Future<DartHttpIsolateWorkerPool> spawn({
    required DartHttpIsolateRequestHandler handler,
    required int size,
    String debugName = 'DartHttpIsolateWorkerPool',
    DartHttpIsolateWorkerPoolStrategy strategy = DartHttpIsolateWorkerPoolStrategy.leastPending,
    int? maxPendingRequestsPerWorker,
    Duration? defaultTimeout,
  }) async {
    if (size < 1) {
      throw ArgumentError.value(size, 'size', 'size must be at least 1.');
    }

    final workers = await Future.wait([
      for (var index = 0; index < size; index++)
        DartHttpIsolateWorker.spawn(
          handler: handler,
          debugName: '$debugName#$index',
          maxPendingRequests: maxPendingRequestsPerWorker,
          defaultTimeout: defaultTimeout,
        ),
    ]);
    return DartHttpIsolateWorkerPool._(
      workers,
      debugName: debugName,
      size: size,
      strategy: strategy,
    );
  }

  Future<T> request<T>(Object? request, {Duration? timeout}) async {
    if (_closed) {
      throw StateError('$debugName is closed.');
    }
    return await _selectWorker().request<T>(request, timeout: timeout);
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await Future.wait([for (final worker in _workers) worker.close()]);
  }

  DartHttpIsolateWorker _selectWorker() {
    return switch (strategy) {
      DartHttpIsolateWorkerPoolStrategy.roundRobin => _workers[_nextWorker++ % _workers.length],
      DartHttpIsolateWorkerPoolStrategy.leastPending => _leastPendingWorker(),
    };
  }

  DartHttpIsolateWorker _leastPendingWorker() {
    var selected = _workers.first;
    for (final worker in _workers.skip(1)) {
      if (worker.pendingRequestCount < selected.pendingRequestCount) {
        selected = worker;
      }
    }
    return selected;
  }
}

final class _PendingRequest {
  const _PendingRequest({required this.completer, required this.timer});

  final Completer<Object?> completer;
  final Timer? timer;
}

final class _WorkerStartMessage {
  const _WorkerStartMessage({
    required this.readyPort,
    required this.responsePort,
    required this.handler,
  });

  final SendPort readyPort;
  final SendPort responsePort;
  final DartHttpIsolateRequestHandler handler;
}

final class _WorkerRequest {
  const _WorkerRequest({required this.id, required this.payload});

  final int id;
  final Object? payload;
}

final class _WorkerResponse {
  const _WorkerResponse.success({required this.id, required this.payload})
    : success = true,
      error = null,
      stackTrace = null;

  const _WorkerResponse.failure({required this.id, required this.error, required this.stackTrace})
    : success = false,
      payload = null;

  final int id;
  final bool success;
  final Object? payload;
  final String? error;
  final String? stackTrace;
}

final class _WorkerCloseMessage {
  const _WorkerCloseMessage();
}

void _workerMain(_WorkerStartMessage start) {
  final commandPort = ReceivePort();
  start.readyPort.send(commandPort.sendPort);
  commandPort.listen((message) async {
    switch (message) {
      case _WorkerCloseMessage():
        commandPort.close();
      case _WorkerRequest():
        try {
          start.responsePort.send(
            _WorkerResponse.success(id: message.id, payload: await start.handler(message.payload)),
          );
        } catch (error, stackTrace) {
          start.responsePort.send(
            _WorkerResponse.failure(
              id: message.id,
              error: error.toString(),
              stackTrace: stackTrace.toString(),
            ),
          );
        }
    }
  });
}
