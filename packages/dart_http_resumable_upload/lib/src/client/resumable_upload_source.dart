import 'dart:typed_data';

/// Repeatable byte source that can reopen content at an arbitrary offset.
abstract interface class ResumableUploadSource {
  int get length;

  Stream<List<int>> openRead({required int offset, required int length});

  factory ResumableUploadSource.bytes(List<int> bytes) = BytesResumableUploadSource;
}

final class BytesResumableUploadSource implements ResumableUploadSource {
  BytesResumableUploadSource(List<int> bytes) : _bytes = Uint8List.fromList(bytes);

  final Uint8List _bytes;

  @override
  int get length => _bytes.length;

  @override
  Stream<List<int>> openRead({required int offset, required int length}) {
    RangeError.checkValidRange(offset, offset + length, _bytes.length);
    return Stream<List<int>>.value(Uint8List.sublistView(_bytes, offset, offset + length));
  }
}

/// Callback-backed upload source suitable for files and platform storage.
final class CallbackResumableUploadSource implements ResumableUploadSource {
  const CallbackResumableUploadSource({required this.length, required this.onOpenRead});

  @override
  final int length;

  final Stream<List<int>> Function({required int offset, required int length}) onOpenRead;

  @override
  Stream<List<int>> openRead({required int offset, required int length}) {
    return onOpenRead(offset: offset, length: length);
  }
}
