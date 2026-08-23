import 'dart:async';

import '../http/http_method.dart';

/// Transport used by a generated client operation.
enum DartEdgeClientOperationKind { http, webSocket, webTransport }

/// Stable metadata for one generated client operation.
final class DartEdgeClientOperationInfo {
  const DartEdgeClientOperationInfo({
    required this.operationId,
    required this.kind,
    required this.pathTemplate,
    this.method,
  });

  final String operationId;
  final DartEdgeClientOperationKind kind;
  final String pathTemplate;
  final HttpMethod? method;
}

enum DartEdgeClientRequestState { pending, succeeded, failed, canceled, timedOut }

/// A request that has started and can be observed or canceled.
final class DartEdgeClientRequestHandle<T> {
  DartEdgeClientRequestHandle._(this.info, this.startedAt, this.future, this._abortCompleter);

  final DartEdgeClientOperationInfo info;
  final DateTime startedAt;
  final Future<T> future;
  final Completer<void> _abortCompleter;

  DateTime? _endedAt;
  DartEdgeClientRequestState _state = DartEdgeClientRequestState.pending;
  Object? _error;

  DateTime? get endedAt => _endedAt;
  DartEdgeClientRequestState get state => _state;
  Object? get error => _error;

  bool get isCanceled => state == DartEdgeClientRequestState.canceled;

  void cancel() {
    if (state == DartEdgeClientRequestState.pending) {
      _state = DartEdgeClientRequestState.canceled;
      _abortCompleter.complete();
    }
  }
}

/// Starts a generated HTTP request and returns its lifecycle handle.
DartEdgeClientRequestHandle<T> startDartEdgeClientRequest<T>({
  required DartEdgeClientOperationInfo info,
  required Future<T> Function(Future<void> abortTrigger) run,
  Duration? timeout,
}) {
  final abortCompleter = Completer<void>();
  late final DartEdgeClientRequestHandle<T> handle;
  Timer? timeoutTimer;

  Future<T> execute() async {
    try {
      final result = await run(abortCompleter.future);
      if (handle.state == DartEdgeClientRequestState.pending) {
        handle._state = DartEdgeClientRequestState.succeeded;
      }
      return result;
    } catch (error) {
      handle._error = error;
      if (handle.state == DartEdgeClientRequestState.pending) {
        handle._state = DartEdgeClientRequestState.failed;
      }
      rethrow;
    } finally {
      timeoutTimer?.cancel();
      handle._endedAt = DateTime.now();
    }
  }

  handle = DartEdgeClientRequestHandle<T>._(
    info,
    DateTime.now(),
    Future<void>.value().then((_) => execute()),
    abortCompleter,
  );
  if (timeout case final timeout?) {
    timeoutTimer = Timer(timeout, () {
      if (handle.state != DartEdgeClientRequestState.pending) {
        return;
      }
      handle._state = DartEdgeClientRequestState.timedOut;
      abortCompleter.complete();
    });
  }
  return handle;
}
