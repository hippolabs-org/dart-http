import 'package:dart_http_core/dart_http_core.dart';

import 'checkpoint.dart';

sealed class ResumableUploadException implements Exception {
  const ResumableUploadException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

final class ResumableUploadProtocolException extends ResumableUploadException {
  const ResumableUploadProtocolException(super.message);
}

final class ResumableUploadRejectedException extends ResumableUploadException {
  ResumableUploadRejectedException(this.response)
    : super('The upload request was rejected with HTTP ${response.status}.');

  final DartHttpClientResponse response;
}

final class ResumableUploadRetryExhaustedException extends ResumableUploadException {
  const ResumableUploadRetryExhaustedException(this.cause)
    : super('The upload could not recover after the configured retry attempts.');

  final Object cause;
}

final class ResumableUploadSourceException extends ResumableUploadException {
  const ResumableUploadSourceException(super.message);
}

final class ResumableUploadPausedException extends ResumableUploadException {
  const ResumableUploadPausedException({required this.checkpoint, required this.cause})
    : super('The upload was paused before completion.');

  final ResumableUploadCheckpoint checkpoint;
  final Object cause;
}

/// Bytes are complete, but application finalization failed or was interrupted.
/// Resume [checkpoint] to retry finalization without retransmitting the source.
final class ResumableUploadFinalizationException extends ResumableUploadException {
  const ResumableUploadFinalizationException({required this.checkpoint, this.response, this.cause})
    : super('Upload bytes are complete, but finalization did not succeed.');

  final ResumableUploadCheckpoint checkpoint;
  final DartHttpClientResponse? response;
  final Object? cause;
}
