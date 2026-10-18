import 'package:dart_http_core/dart_http_core.dart';

import 'checkpoint.dart';

enum ResumableUploadEventType {
  creating,
  inspecting,
  preparing,
  uploading,
  waitingToRetry,
  checkpoint,
  finalizing,
  completed,
  canceled,
}

/// Progress for one attempt. Only [checkpoint] confirms durable receipt.
final class ResumableUploadEvent {
  const ResumableUploadEvent({
    required this.type,
    this.checkpoint,
    this.optimisticOffset,
    this.preparedOffset,
    this.transportOffset,
    this.transportMeasurement,
    this.retryAttempt,
    this.retryDelay,
    this.error,
  });

  final ResumableUploadEventType type;
  final ResumableUploadCheckpoint? checkpoint;

  /// Legacy source-read offset. Never use this as transmitted progress.
  @Deprecated('Use preparedOffset; source reads are not network progress.')
  final int? optimisticOffset;
  final int? preparedOffset;

  /// Confirmed offset plus transport-reported bytes for the current attempt.
  /// Discard this value on retry; it is not a resumable checkpoint.
  final int? transportOffset;
  final DartHttpClientUploadMeasurement? transportMeasurement;
  final int? retryAttempt;
  final Duration? retryDelay;
  final Object? error;

  /// Durable progress. Preparation and transport buffering cannot advance it.
  double? get fraction => checkpoint?.fraction;

  /// In-flight progress, when measured by the transport. This may reach one
  /// before the server confirms the final bytes; [type] still is not completed.
  double? get transportFraction {
    final checkpoint = this.checkpoint;
    final offset = transportOffset;
    if (checkpoint == null || offset == null || checkpoint.totalBytes == 0) return null;
    return (offset / checkpoint.totalBytes).clamp(0, 1).toDouble();
  }
}
