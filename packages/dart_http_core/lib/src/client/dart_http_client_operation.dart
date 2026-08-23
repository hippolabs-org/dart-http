import 'dart:async';

import '../http/http_method.dart';

/// Transport used by a generated client operation.
enum DartHttpClientOperationKind { http, webSocket, webTransport }

/// Stable metadata for one generated client operation.
final class DartHttpClientOperationInfo {
  const DartHttpClientOperationInfo({
    required this.operationId,
    required this.kind,
    required this.pathTemplate,
    this.method,
  });

  final String operationId;
  final DartHttpClientOperationKind kind;
  final String pathTemplate;
  final HttpMethod? method;
}

enum DartHttpClientRequestState { pending, succeeded, failed, canceled, timedOut }

/// A request that has started and can be observed or canceled.
final class DartHttpClientRequestHandle<T> {
  DartHttpClientRequestHandle._(this.info, this.startedAt, this.future, this._abortCompleter);

  final DartHttpClientOperationInfo info;
  final DateTime startedAt;
  final Future<T> future;
  final Completer<void> _abortCompleter;

  DateTime? _endedAt;
  DartHttpClientRequestState _state = DartHttpClientRequestState.pending;
  Object? _error;

  DateTime? get endedAt => _endedAt;
  DartHttpClientRequestState get state => _state;
  Object? get error => _error;

  bool get isCanceled => state == DartHttpClientRequestState.canceled;

  void cancel() {
    if (state == DartHttpClientRequestState.pending) {
      _state = DartHttpClientRequestState.canceled;
      _abortCompleter.complete();
    }
  }
}

/// Starts a generated HTTP request and returns its lifecycle handle.
DartHttpClientRequestHandle<T> startDartHttpClientRequest<T>({
  required DartHttpClientOperationInfo info,
  required Future<T> Function(Future<void> abortTrigger) run,
  Duration? timeout,
}) {
  final abortCompleter = Completer<void>();
  late final DartHttpClientRequestHandle<T> handle;
  Timer? timeoutTimer;

  Future<T> execute() async {
    try {
      final result = await run(abortCompleter.future);
      if (handle.state == DartHttpClientRequestState.pending) {
        handle._state = DartHttpClientRequestState.succeeded;
      }
      return result;
    } catch (error) {
      handle._error = error;
      if (handle.state == DartHttpClientRequestState.pending) {
        handle._state = DartHttpClientRequestState.failed;
      }
      rethrow;
    } finally {
      timeoutTimer?.cancel();
      handle._endedAt = DateTime.now();
    }
  }

  handle = DartHttpClientRequestHandle<T>._(
    info,
    DateTime.now(),
    Future<void>.value().then((_) => execute()),
    abortCompleter,
  );
  if (timeout case final timeout?) {
    timeoutTimer = Timer(timeout, () {
      if (handle.state != DartHttpClientRequestState.pending) {
        return;
      }
      handle._state = DartHttpClientRequestState.timedOut;
      abortCompleter.complete();
    });
  }
  return handle;
}
