import 'checkpoint.dart';

enum ResumableUploadEventType {
  creating,
  inspecting,
  uploading,
  waitingToRetry,
  checkpoint,
  completed,
  canceled,
}

/// One observable upload state transition.
final class ResumableUploadEvent {
  const ResumableUploadEvent({
    required this.type,
    this.checkpoint,
    this.optimisticOffset,
    this.retryAttempt,
    this.retryDelay,
    this.error,
  });

  final ResumableUploadEventType type;
  final ResumableUploadCheckpoint? checkpoint;
  final int? optimisticOffset;
  final int? retryAttempt;
  final Duration? retryDelay;
  final Object? error;

  double? get fraction {
    final checkpoint = this.checkpoint;
    if (checkpoint == null) return null;
    final offset = optimisticOffset ?? checkpoint.offset;
    return checkpoint.complete || checkpoint.totalBytes == 0 ? 1 : offset / checkpoint.totalBytes;
  }
}
