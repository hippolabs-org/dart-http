import 'dart:async';
import 'dart:typed_data';

import '../models/content.dart';
import 'resumable_upload_store.dart';

typedef ResumableUploadIdGenerator = String Function();

/// In-memory reference store intended for tests and examples.
final class InMemoryResumableUploadStore implements ResumableUploadStore {
  InMemoryResumableUploadStore({ResumableUploadIdGenerator? idGenerator})
    : _idGenerator = idGenerator ?? _defaultId;

  final ResumableUploadIdGenerator _idGenerator;
  final Map<String, _Entry> _entries = <String, _Entry>{};
  static var _nextId = 0;

  static String _defaultId() {
    final sequence = _nextId++;
    return 'upload-${DateTime.now().microsecondsSinceEpoch}-$sequence';
  }

  @override
  Future<ResumableUploadResource> create({
    required int length,
    required Map<String, String> metadata,
    Duration? maxAge,
  }) async {
    if (length < 0) {
      throw const ResumableUploadLengthException('Upload length must be non-negative.');
    }
    final id = _idGenerator();
    if (_entries.containsKey(id)) {
      throw StateError('Upload id generator returned duplicate id $id.');
    }
    final entry = _Entry(
      id: id,
      length: length,
      metadata: Map<String, String>.unmodifiable(metadata),
      expiresAt: maxAge == null ? null : DateTime.now().add(maxAge),
    );
    _entries[id] = entry;
    return entry.resource;
  }

  @override
  Future<ResumableUploadResource?> read(String id) async {
    final entry = _activeEntry(id);
    if (entry == null) return null;
    return entry.synchronized(() async {
      if (entry.canceled || _entries[id] != entry) return null;
      return entry.resource;
    });
  }

  @override
  Future<ResumableUploadResource> append({
    required String id,
    required int expectedOffset,
    required ResumableUploadContent content,
    required bool complete,
  }) async {
    final entry = _activeEntry(id);
    if (entry == null) throw ResumableUploadNotFoundException(id);
    return entry.synchronized(() async {
      if (entry.canceled || _entries[id] != entry) {
        throw ResumableUploadNotFoundException(id);
      }
      if (entry.complete) throw ResumableUploadAlreadyCompleteException(id);
      if (entry.bytes.length != expectedOffset) {
        throw ResumableUploadOffsetMismatchException(
          expected: expectedOffset,
          actual: entry.bytes.length,
        );
      }
      await for (final chunk in content.stream) {
        if (entry.bytes.length + chunk.length > entry.length) {
          throw ResumableUploadLengthException(
            'Appending ${chunk.length} bytes would exceed upload length ${entry.length}.',
          );
        }
        entry.bytes.addAll(chunk);
      }
      if (complete && entry.bytes.length != entry.length) {
        throw ResumableUploadLengthException(
          'Cannot complete ${entry.bytes.length}/${entry.length} byte upload.',
        );
      }
      entry.complete = complete;
      return entry.resource;
    });
  }

  @override
  Future<void> cancel(String id) async {
    final entry = _entries[id];
    if (entry == null) return;
    await entry.synchronized(() async {
      entry.canceled = true;
      _entries.remove(id);
    });
  }

  /// Copies the bytes currently held for [id].
  Future<Uint8List?> bytesFor(String id) async {
    final entry = _activeEntry(id);
    if (entry == null) return null;
    return entry.synchronized(() async => Uint8List.fromList(entry.bytes));
  }

  _Entry? _activeEntry(String id) {
    final entry = _entries[id];
    if (entry == null) return null;
    final expiresAt = entry.expiresAt;
    if (expiresAt != null && !expiresAt.isAfter(DateTime.now())) {
      _entries.remove(id);
      return null;
    }
    return entry;
  }
}

final class _Entry {
  _Entry({required this.id, required this.length, required this.metadata, required this.expiresAt});

  final String id;
  final int length;
  final Map<String, String> metadata;
  final DateTime? expiresAt;
  final List<int> bytes = <int>[];
  bool complete = false;
  bool canceled = false;
  Future<void> _tail = Future<void>.value();

  ResumableUploadResource get resource => ResumableUploadResource(
    id: id,
    offset: bytes.length,
    length: length,
    complete: complete,
    metadata: metadata,
    expiresAt: expiresAt,
  );

  Future<T> synchronized<T>(Future<T> Function() operation) async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await previous;
    try {
      return await operation();
    } finally {
      release.complete();
    }
  }
}
