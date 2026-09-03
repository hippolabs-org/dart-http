import 'package:dart_http_core/dart_http_core.dart';

import 'checkpoint.dart';

/// Successful completion of a resumable upload.
final class ResumableUploadResult {
  const ResumableUploadResult({required this.checkpoint, required this.response});

  final ResumableUploadCheckpoint checkpoint;
  final DartHttpClientResponse response;
}
