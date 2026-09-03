import 'dart:async';
import 'dart:math' as math;

import 'package:dart_http_core/dart_http_core.dart';

import '../models/checkpoint.dart';
import '../models/events.dart';
import '../models/exceptions.dart';
import '../models/limits.dart';
import '../models/result.dart';
import '../protocol/resumable_upload_protocol.dart';
import 'resumable_upload_source.dart';

typedef ResumableUploadDelay = Future<void> Function(Duration duration);

final class ResumableUploadRetryPolicy {
  const ResumableUploadRetryPolicy({
    this.maxRetries = 3,
    this.initialDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 8),
  }) : assert(maxRetries >= 0);

  final int maxRetries;
  final Duration initialDelay;
  final Duration maxDelay;

  Duration delayFor(int retryAttempt) {
    if (retryAttempt <= 0 || initialDelay == Duration.zero) return Duration.zero;
    final multiplier = 1 << math.min(retryAttempt - 1, 30);
    final milliseconds = math.min(
      initialDelay.inMilliseconds * multiplier,
      maxDelay.inMilliseconds,
    );
    return Duration(milliseconds: milliseconds);
  }
}

/// Coordinates careful creation, append, offset recovery, and cancellation.
final class ResumableUploadClient {
  ResumableUploadClient({
    required this.transport,
    this.chunkSize = 8 * 1024 * 1024,
    this.retryPolicy = const ResumableUploadRetryPolicy(),
    ResumableUploadDelay? delay,
  }) : _delay = delay ?? Future<void>.delayed,
       assert(chunkSize > 0);

  final HttpClientTransport transport;
  final int chunkSize;
  final ResumableUploadRetryPolicy retryPolicy;
  final ResumableUploadDelay _delay;

  Future<ResumableUploadResult> start({
    required Uri creationUri,
    required ResumableUploadSource source,
    Map<String, String> headers = const <String, String>{},
    void Function(ResumableUploadCheckpoint checkpoint)? onCheckpoint,
    void Function(ResumableUploadEvent event)? onEvent,
    Future<void>? abortTrigger,
  }) async {
    onEvent?.call(const ResumableUploadEvent(type: ResumableUploadEventType.creating));
    final response = await transport.send(
      DartHttpClientRequest(
        method: HttpMethod.post,
        uri: creationUri,
        headers: <String, String>{
          ...headers,
          ResumableUploadProtocol.draftInteropVersionHeader:
              '${ResumableUploadProtocol.draftInteropVersion}',
          ResumableUploadProtocol.completeHeader: ResumableUploadProtocol.encodeBoolean(false),
          ResumableUploadProtocol.lengthHeader: '${source.length}',
        },
        bodyBytes: const <int>[],
        abortTrigger: abortTrigger,
      ),
    );
    _requireSuccess(response);
    final location = ResumableUploadProtocol.header(response.headers, 'location');
    if (location == null || location.trim().isEmpty) {
      throw const ResumableUploadProtocolException(
        'Upload creation response did not include Location.',
      );
    }

    final checkpoint = ResumableUploadCheckpoint(
      uploadUri: creationUri.resolve(location),
      offset: 0,
      totalBytes: source.length,
    );
    _emitCheckpoint(checkpoint, onCheckpoint: onCheckpoint, onEvent: onEvent);
    return _uploadFrom(
      checkpoint,
      source,
      limits: _responseLimits(response),
      headers: headers,
      onCheckpoint: onCheckpoint,
      onEvent: onEvent,
      abortTrigger: abortTrigger,
    );
  }

  Future<ResumableUploadResult> resume({
    required ResumableUploadCheckpoint checkpoint,
    required ResumableUploadSource source,
    Map<String, String> headers = const <String, String>{},
    void Function(ResumableUploadCheckpoint checkpoint)? onCheckpoint,
    void Function(ResumableUploadEvent event)? onEvent,
    Future<void>? abortTrigger,
  }) async {
    if (source.length != checkpoint.totalBytes) {
      throw ResumableUploadSourceException(
        'Upload source length changed from ${checkpoint.totalBytes} to ${source.length}.',
      );
    }
    final inspection = await _inspect(
      checkpoint.uploadUri,
      expectedLength: checkpoint.totalBytes,
      headers: headers,
      onEvent: onEvent,
      abortTrigger: abortTrigger,
    );
    _emitCheckpoint(inspection.checkpoint, onCheckpoint: onCheckpoint, onEvent: onEvent);
    if (inspection.checkpoint.complete) {
      onEvent?.call(
        ResumableUploadEvent(
          type: ResumableUploadEventType.completed,
          checkpoint: inspection.checkpoint,
        ),
      );
      return ResumableUploadResult(
        checkpoint: inspection.checkpoint,
        response: inspection.response,
      );
    }
    return _uploadFrom(
      inspection.checkpoint,
      source,
      limits: inspection.limits,
      headers: headers,
      onCheckpoint: onCheckpoint,
      onEvent: onEvent,
      abortTrigger: abortTrigger,
    );
  }

  Future<ResumableUploadCheckpoint> inspect({
    required Uri uploadUri,
    required int expectedLength,
    Map<String, String> headers = const <String, String>{},
    Future<void>? abortTrigger,
  }) async {
    return (await _inspect(
      uploadUri,
      expectedLength: expectedLength,
      headers: headers,
      abortTrigger: abortTrigger,
    )).checkpoint;
  }

  Future<void> cancel({
    required ResumableUploadCheckpoint checkpoint,
    Map<String, String> headers = const <String, String>{},
    void Function(ResumableUploadEvent event)? onEvent,
    Future<void>? abortTrigger,
  }) async {
    final response = await transport.send(
      DartHttpClientRequest(
        method: HttpMethod.delete,
        uri: checkpoint.uploadUri,
        headers: <String, String>{
          ...headers,
          ResumableUploadProtocol.draftInteropVersionHeader:
              '${ResumableUploadProtocol.draftInteropVersion}',
        },
        abortTrigger: abortTrigger,
      ),
    );
    _requireSuccess(response);
    onEvent?.call(
      ResumableUploadEvent(type: ResumableUploadEventType.canceled, checkpoint: checkpoint),
    );
  }

  Future<ResumableUploadResult> _uploadFrom(
    ResumableUploadCheckpoint initial,
    ResumableUploadSource source, {
    required ResumableUploadLimits? limits,
    required Map<String, String> headers,
    required void Function(ResumableUploadCheckpoint checkpoint)? onCheckpoint,
    required void Function(ResumableUploadEvent event)? onEvent,
    required Future<void>? abortTrigger,
  }) async {
    var checkpoint = initial;
    var currentLimits = limits;
    var retryAttempt = 0;
    var aborted = false;
    abortTrigger?.then<void>((_) => aborted = true);

    if (currentLimits?.maxSize case final maxSize? when checkpoint.totalBytes > maxSize) {
      throw ResumableUploadProtocolException(
        'Upload length ${checkpoint.totalBytes} exceeds the server maximum $maxSize.',
      );
    }
    if (currentLimits?.minSize case final minSize? when checkpoint.totalBytes < minSize) {
      throw ResumableUploadProtocolException(
        'Upload length ${checkpoint.totalBytes} is below the server minimum $minSize.',
      );
    }

    while (!checkpoint.complete) {
      final remaining = checkpoint.totalBytes - checkpoint.offset;
      final appendLength = math.min(
        math.min(chunkSize, currentLimits?.maxAppendSize ?? chunkSize),
        remaining,
      );
      final completesUpload = checkpoint.offset + appendLength == checkpoint.totalBytes;
      final minAppendSize = currentLimits?.minAppendSize;
      if (!completesUpload && minAppendSize != null && appendLength < minAppendSize) {
        throw ResumableUploadProtocolException(
          'Configured chunk size $appendLength is below the server minimum $minAppendSize.',
        );
      }
      try {
        final response = await transport.send(
          DartHttpClientRequest(
            method: HttpMethod.patch,
            uri: checkpoint.uploadUri,
            headers: <String, String>{
              ...headers,
              'content-type': ResumableUploadProtocol.partialUploadMediaType,
              ResumableUploadProtocol.draftInteropVersionHeader:
                  '${ResumableUploadProtocol.draftInteropVersion}',
              ResumableUploadProtocol.offsetHeader: '${checkpoint.offset}',
              ResumableUploadProtocol.lengthHeader: '${checkpoint.totalBytes}',
              ResumableUploadProtocol.completeHeader: ResumableUploadProtocol.encodeBoolean(
                completesUpload,
              ),
            },
            bodyStream: _trackedChunk(
              source,
              checkpoint: checkpoint,
              length: appendLength,
              onEvent: onEvent,
            ),
            bodyStreamLength: appendLength,
            abortTrigger: abortTrigger,
          ),
        );

        final responseComplete = ResumableUploadProtocol.parseBoolean(
          ResumableUploadProtocol.header(response.headers, ResumableUploadProtocol.completeHeader),
        );
        if (responseComplete == true) {
          final responseOffset = ResumableUploadProtocol.parseNonNegativeInteger(
            ResumableUploadProtocol.header(response.headers, ResumableUploadProtocol.offsetHeader),
          );
          if (responseOffset != null) {
            _validateOffset(responseOffset, checkpoint: checkpoint);
          }
          checkpoint = checkpoint.copyWith(
            offset: responseOffset ?? checkpoint.offset,
            complete: true,
          );
          _emitCheckpoint(checkpoint, onCheckpoint: onCheckpoint, onEvent: onEvent);
          onEvent?.call(
            ResumableUploadEvent(type: ResumableUploadEventType.completed, checkpoint: checkpoint),
          );
          return ResumableUploadResult(checkpoint: checkpoint, response: response);
        }

        if (!_isSuccess(response.status)) {
          if (!_isRetryable(response.status)) throw ResumableUploadRejectedException(response);
          throw _RetryableResponseException(response);
        }

        final complete = _requiredComplete(response.headers);
        final responseOffset = ResumableUploadProtocol.parseNonNegativeInteger(
          ResumableUploadProtocol.header(response.headers, ResumableUploadProtocol.offsetHeader),
        );
        final nextOffset = responseOffset ?? checkpoint.offset + appendLength;
        _validateOffset(nextOffset, checkpoint: checkpoint);
        if (nextOffset == checkpoint.offset && appendLength > 0) {
          throw const ResumableUploadProtocolException(
            'Successful append response did not advance the upload offset.',
          );
        }

        checkpoint = checkpoint.copyWith(offset: nextOffset, complete: complete);
        retryAttempt = 0;
        _emitCheckpoint(checkpoint, onCheckpoint: onCheckpoint, onEvent: onEvent);
        if (complete) {
          onEvent?.call(
            ResumableUploadEvent(type: ResumableUploadEventType.completed, checkpoint: checkpoint),
          );
          return ResumableUploadResult(checkpoint: checkpoint, response: response);
        }
      } on ResumableUploadException {
        rethrow;
      } catch (error) {
        var recoveryError = error;
        while (true) {
          if (aborted) {
            throw ResumableUploadPausedException(checkpoint: checkpoint, cause: recoveryError);
          }
          retryAttempt += 1;
          if (retryAttempt > retryPolicy.maxRetries) {
            throw ResumableUploadRetryExhaustedException(recoveryError);
          }
          final delay = retryPolicy.delayFor(retryAttempt);
          onEvent?.call(
            ResumableUploadEvent(
              type: ResumableUploadEventType.waitingToRetry,
              checkpoint: checkpoint,
              retryAttempt: retryAttempt,
              retryDelay: delay,
              error: recoveryError,
            ),
          );
          await _delay(delay);
          if (aborted) {
            throw ResumableUploadPausedException(checkpoint: checkpoint, cause: recoveryError);
          }
          try {
            final inspection = await _inspect(
              checkpoint.uploadUri,
              expectedLength: checkpoint.totalBytes,
              headers: headers,
              onEvent: onEvent,
              abortTrigger: abortTrigger,
            );
            checkpoint = inspection.checkpoint;
            currentLimits = inspection.limits ?? currentLimits;
            _emitCheckpoint(checkpoint, onCheckpoint: onCheckpoint, onEvent: onEvent);
            if (checkpoint.complete) {
              onEvent?.call(
                ResumableUploadEvent(
                  type: ResumableUploadEventType.completed,
                  checkpoint: checkpoint,
                ),
              );
              return ResumableUploadResult(checkpoint: checkpoint, response: inspection.response);
            }
            break;
          } on ResumableUploadException {
            rethrow;
          } catch (error) {
            recoveryError = error;
          }
        }
      }
    }

    throw const ResumableUploadProtocolException('Upload loop ended without a final response.');
  }

  Future<_Inspection> _inspect(
    Uri uploadUri, {
    required int expectedLength,
    required Map<String, String> headers,
    void Function(ResumableUploadEvent event)? onEvent,
    Future<void>? abortTrigger,
  }) async {
    onEvent?.call(const ResumableUploadEvent(type: ResumableUploadEventType.inspecting));
    final response = await transport.send(
      DartHttpClientRequest(
        method: HttpMethod.head,
        uri: uploadUri,
        headers: <String, String>{
          ...headers,
          ResumableUploadProtocol.draftInteropVersionHeader:
              '${ResumableUploadProtocol.draftInteropVersion}',
        },
        abortTrigger: abortTrigger,
      ),
    );
    if (!_isSuccess(response.status)) {
      if (_isRetryable(response.status)) throw _RetryableResponseException(response);
      throw ResumableUploadRejectedException(response);
    }
    final offset = ResumableUploadProtocol.parseNonNegativeInteger(
      ResumableUploadProtocol.header(response.headers, ResumableUploadProtocol.offsetHeader),
    );
    final length = ResumableUploadProtocol.parseNonNegativeInteger(
      ResumableUploadProtocol.header(response.headers, ResumableUploadProtocol.lengthHeader),
    );
    final complete = ResumableUploadProtocol.parseBoolean(
      ResumableUploadProtocol.header(response.headers, ResumableUploadProtocol.completeHeader),
    );
    if (offset == null || complete == null) {
      throw const ResumableUploadProtocolException(
        'Offset response did not include valid Upload-Offset and Upload-Complete headers.',
      );
    }
    if (length != null && length != expectedLength) {
      throw ResumableUploadSourceException(
        'Server upload length changed from $expectedLength to $length.',
      );
    }
    if (offset > expectedLength) {
      throw ResumableUploadProtocolException(
        'Server offset $offset exceeds upload length $expectedLength.',
      );
    }
    return _Inspection(
      checkpoint: ResumableUploadCheckpoint(
        uploadUri: uploadUri,
        offset: offset,
        totalBytes: expectedLength,
        complete: complete,
      ),
      response: response,
      limits: _responseLimits(response),
    );
  }

  Stream<List<int>> _trackedChunk(
    ResumableUploadSource source, {
    required ResumableUploadCheckpoint checkpoint,
    required int length,
    required void Function(ResumableUploadEvent event)? onEvent,
  }) async* {
    var emitted = 0;
    await for (final chunk in source.openRead(offset: checkpoint.offset, length: length)) {
      if (chunk.isEmpty) continue;
      if (emitted + chunk.length > length) {
        throw const ResumableUploadSourceException(
          'Upload source emitted more bytes than requested.',
        );
      }
      emitted += chunk.length;
      onEvent?.call(
        ResumableUploadEvent(
          type: ResumableUploadEventType.uploading,
          checkpoint: checkpoint,
          optimisticOffset: checkpoint.offset + emitted,
        ),
      );
      yield chunk;
    }
    if (emitted != length) {
      throw ResumableUploadSourceException(
        'Upload source emitted $emitted bytes, expected $length.',
      );
    }
  }

  static void _emitCheckpoint(
    ResumableUploadCheckpoint checkpoint, {
    required void Function(ResumableUploadCheckpoint checkpoint)? onCheckpoint,
    required void Function(ResumableUploadEvent event)? onEvent,
  }) {
    onCheckpoint?.call(checkpoint);
    onEvent?.call(
      ResumableUploadEvent(type: ResumableUploadEventType.checkpoint, checkpoint: checkpoint),
    );
  }

  static bool _requiredComplete(Map<String, String> headers) {
    final complete = ResumableUploadProtocol.parseBoolean(
      ResumableUploadProtocol.header(headers, ResumableUploadProtocol.completeHeader),
    );
    if (complete == null) {
      throw const ResumableUploadProtocolException(
        'Append response did not include a valid Upload-Complete header.',
      );
    }
    return complete;
  }

  static void _validateOffset(int offset, {required ResumableUploadCheckpoint checkpoint}) {
    if (offset < checkpoint.offset || offset > checkpoint.totalBytes) {
      throw ResumableUploadProtocolException(
        'Server returned invalid upload offset $offset for '
        '${checkpoint.offset}/${checkpoint.totalBytes}.',
      );
    }
  }

  static void _requireSuccess(DartHttpClientResponse response) {
    if (!_isSuccess(response.status)) throw ResumableUploadRejectedException(response);
  }

  static bool _isSuccess(int status) => status >= 200 && status < 300;

  static bool _isRetryable(int status) {
    return status == 408 || status == 409 || status == 425 || status == 429 || status >= 500;
  }

  static ResumableUploadLimits? _responseLimits(DartHttpClientResponse response) {
    return ResumableUploadLimits.parse(
      ResumableUploadProtocol.header(response.headers, ResumableUploadProtocol.limitHeader),
    );
  }
}

final class _Inspection {
  const _Inspection({required this.checkpoint, required this.response, required this.limits});

  final ResumableUploadCheckpoint checkpoint;
  final DartHttpClientResponse response;
  final ResumableUploadLimits? limits;
}

final class _RetryableResponseException implements Exception {
  const _RetryableResponseException(this.response);

  final DartHttpClientResponse response;
}
