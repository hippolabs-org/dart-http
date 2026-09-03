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
