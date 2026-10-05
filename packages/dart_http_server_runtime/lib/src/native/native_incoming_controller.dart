import 'dart:async';

/// Pulls only while the application consumes, yielding between native payloads.
/// The native reservation remains attached to each payload until release.
final class NativeIncomingController<T> {
  NativeIncomingController({
    required this.take,
    required this.discard,
    required this.cancel,
    this.onListen,
  }) {
    _controller = StreamController<T>(
      onListen: () {
        onListen?.call();
        wake();
      },
      onResume: wake,
      onCancel: dispose,
    );
  }

  final T? Function() take;
  final void Function(T) discard;
  final void Function() cancel;
  final void Function()? onListen;
  late final StreamController<T> _controller;
  final _finished = Completer<void>();
  bool _scheduled = false;
  bool _finishing = false;
  bool _disposed = false;
  void Function()? _releasePrevious;

  Stream<T> get stream => _controller.stream;
  bool get hasListener => _controller.hasListener;
  bool get isClosed => _disposed || _controller.isClosed;

  /// Text buffers may be copied, but their reservation lasts until delivery.
  void holdRelease(void Function() release) {
    if (_disposed) {
      release();
    } else {
      _releasePrevious?.call();
      _releasePrevious = release;
    }
  }

  void wake() {
    if (_scheduled || isClosed || !_controller.hasListener || _controller.isPaused) return;
    _scheduled = true;
    Timer.run(() {
      _scheduled = false;
      if (isClosed || !_controller.hasListener || _controller.isPaused) return;
      final release = _releasePrevious;
      _releasePrevious = null;
      release?.call();
      final value = take();
      if (value != null) {
        _controller.add(value);
        wake();
      } else if (_finishing) {
        unawaited(
          _controller.close().whenComplete(() {
            if (!_finished.isCompleted) _finished.complete();
          }),
        );
      }
    });
  }

  void addError(Object error) => _controller.addError(error);

  /// Preserves queued final frames and exposes done after the consumer drains.
  Future<void> close() {
    _finishing = true;
    wake();
    return _finished.future;
  }

  /// Cancels intake and releases queued ownership without waiting for a paused
  /// or absent application listener.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancel();
    _releasePrevious?.call();
    _releasePrevious = null;
    while (true) {
      final value = take();
      if (value == null) break;
      discard(value);
    }
    _releasePrevious?.call();
    _releasePrevious = null;
    unawaited(_controller.close());
    if (!_finished.isCompleted) _finished.complete();
  }
}
