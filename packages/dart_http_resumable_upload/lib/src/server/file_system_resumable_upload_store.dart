import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_http_core/dart_http_core.dart';

import '../models/content.dart';
import 'resumable_upload_store.dart';

/// Persistent byte spools and finalization results on an application-owned volume.
///
/// Use one store-owning isolate per process. Instances in that isolate share a
/// mutex, while OS file locks serialize processes using the same filesystem.
/// Shared volumes must support advisory locks and atomic replacement by rename.
/// Confirmed metadata is written after flushing bytes; recovery truncates any
/// unconfirmed suffix. Never place this directory in a disposable temp volume.
final class FileSystemResumableUploadStore implements ResumableUploadFinalizationStore {
  FileSystemResumableUploadStore({required Directory directory, DateTime Function()? clock})
    : directory = directory.absolute,
      _clock = clock ?? DateTime.now;

  final Directory directory;
  final DateTime Function() _clock;
  static final _tails = <String, Future<void>>{};
  static final _random = Random.secure();
  static final _validId = RegExp(r'^[a-f0-9]{32}$');

  /// Immutable source for a complete upload. Validate access and completion
  /// before reading it. Do not delete/move this file; finalization may replay.
  File payloadFile(String id) {
    _validateId(id);
    return File('${directory.path}/$id/body');
  }

  @override
  Future<ResumableUploadResource> create({
    required int length,
    required Map<String, String> metadata,
    Duration? maxAge,
  }) async {
    if (length < 0 || (maxAge != null && maxAge <= Duration.zero)) {
      throw ArgumentError('Upload length and lifetime must be valid.');
    }
    await directory.create(recursive: true);
    final id = List.generate(
      16,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return _locked(id, () async {
      await Directory('${directory.path}/$id').create();
      await payloadFile(id).writeAsBytes(const [], flush: true);
      final state = <String, Object?>{
        'id': id,
        'offset': 0,
        'length': length,
        'complete': false,
        'metadata': metadata,
        'expires_at': maxAge == null ? null : _clock().toUtc().add(maxAge).toIso8601String(),
      };
      await _save(id, state);
      return _resource(state);
    });
  }

  @override
  Future<ResumableUploadResource?> read(String id) async {
    if (!_validId.hasMatch(id)) return null;
    return _locked(id, () async {
      final state = await _load(id);
      return state == null ? null : _resource(state);
    });
  }

  @override
  Future<ResumableUploadResource> append({
    required String id,
    required int expectedOffset,
    required ResumableUploadContent content,
    required bool complete,
  }) => _locked(id, () async {
    final state = await _require(id);
    final resource = _resource(state);
    if (resource.complete) throw ResumableUploadAlreadyCompleteException(id);
    if (expectedOffset != resource.offset) {
      throw ResumableUploadOffsetMismatchException(
        expected: expectedOffset,
        actual: resource.offset,
      );
    }
    if (content.length < 0 || expectedOffset + content.length > resource.length) {
      throw const ResumableUploadLengthException('Append exceeds the declared upload length.');
    }
    final file = await payloadFile(id).open(mode: FileMode.append);
    var accepted = 0;
    try {
      // A crashed operation may have written bytes without confirming them.
      if (await file.length() < resource.offset) {
        throw StateError('Confirmed upload bytes are missing.');
      }
      await file.truncate(resource.offset);
      await file.setPosition(resource.offset);
      try {
        await for (final chunk in content.stream) {
          if (accepted + chunk.length > content.length) {
            throw const ResumableUploadLengthException(
              'Append source exceeded its declared length.',
            );
          }
          await file.writeFrom(chunk);
          accepted += chunk.length;
        }
        if (accepted != content.length ||
            (complete && resource.offset + accepted != resource.length)) {
          throw const ResumableUploadLengthException(
            'Append source ended before its declared length.',
          );
        }
        state['complete'] = complete;
      } finally {
        // Preserve a valid received prefix even when the connection breaks.
        await file.flush();
        state['offset'] = resource.offset + accepted;
        await _save(id, state);
      }
    } finally {
      await file.close();
    }
    return _resource(state);
  });

  @override
  Future<RawResponse> finalize(String id, FutureOr<RawResponse> Function() operation) => _locked(
    id,
    () async {
      final state = await _locked(id, () => _require(id));
      if (state['complete'] != true) {
        throw const ResumableUploadLengthException('Upload is incomplete.');
      }
      if (state['response'] case final Map cached) return _response(cached.cast<String, Object?>());
      final response = await operation();
      if (response.status >= 200 && response.status < 300) {
        // Only finite JSON/text/binary responses are persistable. No streams.
        state['response'] = <String, Object?>{
          'status': response.status,
          'content_type': response.contentType,
          'body': response.body is Uint8List
              ? base64Encode(response.body as Uint8List)
              : response.body,
          'binary': response.body is Uint8List,
          'encoded': response.isEncodedBody,
          'headers': [
            for (final h in response.headers) [h.name, h.value],
          ],
        };
        await _locked(id, () => _save(id, state));
      }
      return response;
    },
    finalization: true,
  );

  @override
  Future<void> cancel(String id) async {
    if (!_validId.hasMatch(id)) return;
    await _locked(id, () => _locked(id, () => _remove(id)), finalization: true);
  }

  /// Removes expired session data. Permanent lock files prevent inode races
  /// with other processes already waiting on an upload's lock.
  Future<int> deleteExpired() async {
    if (!await directory.exists()) return 0;
    var count = 0;
    await for (final entry in directory.list()) {
      final id = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (entry is! Directory || !_validId.hasMatch(id)) continue;
      await _locked(
        id,
        () => _locked(id, () async {
          final state = await _load(id, includeExpired: true);
          if (state == null || !_expired(state)) return;
          await _remove(id);
          count++;
        }),
        finalization: true,
      );
    }
    return count;
  }

  Future<Map<String, Object?>> _require(String id) async =>
      await _load(id) ?? (throw ResumableUploadNotFoundException(id));

  bool _expired(Map<String, Object?> state) => switch (state['expires_at']) {
    final String value => !DateTime.parse(value).isAfter(_clock().toUtc()),
    _ => false,
  };

  Future<Map<String, Object?>?> _load(String id, {bool includeExpired = false}) async {
    final metadata = File('${directory.path}/$id/state.json');
    if (!await metadata.exists()) return null;
    final state = (jsonDecode(await metadata.readAsString()) as Map).cast<String, Object?>();
    if (!includeExpired && _expired(state)) return null;
    return state;
  }

  Future<void> _save(String id, Map<String, Object?> state) async {
    final target = '${directory.path}/$id/state.json';
    final staging = File('$target.next');
    await staging.writeAsString(jsonEncode(state), flush: true);
    await staging.rename(target);
  }

  Future<void> _remove(String id) async {
    final folder = Directory('${directory.path}/$id');
    if (await folder.exists()) await folder.delete(recursive: true);
  }

  Future<T> _locked<T>(
    String id,
    Future<T> Function() operation, {
    bool finalization = false,
  }) async {
    _validateId(id);
    final suffix = finalization ? '$id.finalize' : id;
    await directory.create(recursive: true);
    final key = '${await directory.resolveSymbolicLinks()}/$suffix';
    final previous = _tails[key] ?? Future<void>.value();
    final done = Completer<void>();
    _tails[key] = done.future;
    await previous;
    RandomAccessFile? lock;
    try {
      final locks = await Directory('${directory.path}/.locks').create(recursive: true);
      lock = await File('${locks.path}/$suffix').open(mode: FileMode.append);
      await lock.lock(FileLock.blockingExclusive);
      return await operation();
    } finally {
      try {
        if (lock != null) {
          try {
            await lock.unlock();
          } finally {
            await lock.close();
          }
        }
      } finally {
        done.complete();
        if (identical(_tails[key], done.future)) _tails.remove(key);
      }
    }
  }

  static void _validateId(String id) {
    if (!_validId.hasMatch(id)) throw ArgumentError.value(id, 'id', 'Invalid upload identifier.');
  }

  static ResumableUploadResource _resource(Map<String, Object?> state) => ResumableUploadResource(
    id: state['id']! as String,
    offset: state['offset']! as int,
    length: state['length']! as int,
    complete: state['complete']! as bool,
    metadata: Map<String, String>.unmodifiable((state['metadata']! as Map).cast<String, String>()),
    expiresAt: state['expires_at'] == null ? null : DateTime.parse(state['expires_at']! as String),
  );
  static RawResponse _response(Map<String, Object?> value) => RawResponse(
    status: value['status']! as int,
    contentType: value['content_type']! as String,
    body: value['binary'] == true ? base64Decode(value['body']! as String) : value['body'],
    isEncodedBody: value['encoded']! as bool,
    headers: [
      for (final pair in value['headers']! as List)
        HttpHeader(pair[0] as String, pair[1] as String),
    ],
  );
}
