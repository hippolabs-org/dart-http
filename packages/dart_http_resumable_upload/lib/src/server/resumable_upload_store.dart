import 'dart:async';

import 'package:dart_http_core/dart_http_core.dart';

import '../models/content.dart';

/// Server-side state for one temporary upload resource.
final class ResumableUploadResource {
  const ResumableUploadResource({
    required this.id,
    required this.offset,
    required this.length,
    required this.complete,
    required this.metadata,
    this.expiresAt,
  });

  final String id;
  final int offset;
  final int length;
  final bool complete;
  final Map<String, String> metadata;
  final DateTime? expiresAt;
}

/// Durable application-owned storage for resumable upload resources.
abstract interface class ResumableUploadStore {
  Future<ResumableUploadResource> create({
    required int length,
    required Map<String, String> metadata,
    Duration? maxAge,
  });

  Future<ResumableUploadResource?> read(String id);

  /// Atomically validates [expectedOffset], appends [content], and advances
  /// the stored offset.
  ///
  /// Implementations must serialize mutations for a resource. Native-capable
  /// stores should adopt [ResumableUploadContent.nativeStream] directly. If
  /// the stream is interrupted, preserve the longest continuous prefix that
  /// was durably written and report that offset from subsequent [read] calls.
  Future<ResumableUploadResource> append({
    required String id,
    required int expectedOffset,
    required ResumableUploadContent content,
    required bool complete,
  });

  Future<void> cancel(String id);
}

/// Stores that coordinate and persist application finalization results.
///
/// Serialize finalization with append/cancel, require complete bytes, and cache
/// successful responses durably. Failures must remain retryable. The callback
/// must itself be idempotent: a process can crash after its side effects but
/// before its response is persisted. Keep domain storage out of HTTP core.
abstract interface class ResumableUploadFinalizationStore implements ResumableUploadStore {
  Future<RawResponse> finalize(String id, FutureOr<RawResponse> Function() operation);
}

/// Marker for stores that adopt runtime-native upload streams directly.
///
/// Routes backed by this interface use `RequestBody.binaryStream`; other
/// stores retain the buffered binary request path.
abstract interface class NativeResumableUploadStore implements ResumableUploadStore {}

sealed class ResumableUploadStoreException implements Exception {
  const ResumableUploadStoreException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

final class ResumableUploadNotFoundException extends ResumableUploadStoreException {
  const ResumableUploadNotFoundException(String id) : super('Upload resource $id was not found.');
}

final class ResumableUploadOffsetMismatchException extends ResumableUploadStoreException {
  const ResumableUploadOffsetMismatchException({required this.expected, required this.actual})
    : super('Expected upload offset $expected, actual offset is $actual.');

  final int expected;
  final int actual;
}

final class ResumableUploadLengthException extends ResumableUploadStoreException {
  const ResumableUploadLengthException(super.message);
}

final class ResumableUploadAlreadyCompleteException extends ResumableUploadStoreException {
  const ResumableUploadAlreadyCompleteException(String id)
    : super('Upload resource $id is already complete.');
}
