import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'sse_decode_exception.dart';
import 'sse_decode_limits.dart';
import 'sse_event.dart';

/// Decodes one byte stream into Server-Sent Events frames.
Stream<SseEvent> decodeSseEvents(
  Stream<List<int>> stream, {
  SseDecodeLimits limits = const SseDecodeLimits(),
}) => SseDecoder(limits: limits).bind(stream);

/// Incrementally decodes byte chunks into [SseEvent] values.
final class SseDecoder extends StreamTransformerBase<List<int>, SseEvent> {
  const SseDecoder({this.limits = const SseDecodeLimits()});

  final SseDecodeLimits limits;

  @override
  Stream<SseEvent> bind(Stream<List<int>> stream) => _decode(stream, limits);
}

Stream<SseEvent> _decode(Stream<List<int>> stream, SseDecodeLimits limits) async* {
  limits.validate();
  final lineBytes = BytesBuilder(copy: false);
  final frame = _SseFrameAccumulator(limits);
  var lineByteCount = 0;
  var firstLine = true;
  var previousWasCarriageReturn = false;

  SseEvent? finishLine() {
    var line = _decodeLine(lineBytes.takeBytes());
    lineByteCount = 0;
    if (firstLine) {
      firstLine = false;
      if (line.value.startsWith('\uFEFF')) {
        line = (value: line.value.substring(1), encodedByteCount: line.encodedByteCount - 3);
      }
    }
    return frame.addLine(line.value, line.encodedByteCount);
  }

  await for (final chunk in stream) {
    for (final byte in chunk) {
      if (byte < 0 || byte > 255) {
        throw const SseDecodeException(
          code: SseDecodeErrorCode.invalidByte,
          message: 'The SSE stream contains a value outside the byte range.',
        );
      }
      if (previousWasCarriageReturn) {
        previousWasCarriageReturn = false;
        if (byte == 0x0a) continue;
      }
      if (byte == 0x0d) {
        final completed = finishLine();
        previousWasCarriageReturn = true;
        if (completed != null) yield completed;
        continue;
      }
      if (byte == 0x0a) {
        final completed = finishLine();
        if (completed != null) yield completed;
        continue;
      }
      if (lineByteCount >= limits.maxLineBytes) {
        throw const SseDecodeException(
          code: SseDecodeErrorCode.lineTooLarge,
          message: 'An SSE line exceeds the configured byte limit.',
        );
      }
      lineBytes.addByte(byte);
      lineByteCount++;
    }
  }

  if (lineByteCount > 0) {
    final completed = finishLine();
    if (completed != null) yield completed;
  }
  final completed = frame.flush();
  if (completed != null) yield completed;
}

final class _SseFrameAccumulator {
  _SseFrameAccumulator(this.limits);

  final SseDecodeLimits limits;
  String? _id;
  String? _event;
  Duration? _retry;
  final List<String> _dataLines = <String>[];
  final List<String> _commentLines = <String>[];
  int _frameBytes = 0;

  SseEvent? addLine(String line, int encodedByteCount) {
    if (line.isEmpty) return flush();
    if (line.startsWith(':')) {
      final comment = line.substring(1);
      final value = comment.startsWith(' ') ? comment.substring(1) : comment;
      _retain(encodedByteCount);
      _commentLines.add(value);
      return null;
    }

    final separator = line.indexOf(':');
    final field = separator < 0 ? line : line.substring(0, separator);
    var value = separator < 0 ? '' : line.substring(separator + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'id':
        if (!value.contains('\u0000')) {
          _retain(encodedByteCount);
          _id = value;
        }
      case 'event':
        if (utf8.encode(value).length > limits.maxEventNameBytes) {
          throw const SseDecodeException(
            code: SseDecodeErrorCode.eventNameTooLarge,
            message: 'An SSE event name exceeds the configured byte limit.',
          );
        }
        _retain(encodedByteCount);
        _event = value;
      case 'data':
        if (_dataLines.length >= limits.maxDataLines) {
          throw const SseDecodeException(
            code: SseDecodeErrorCode.dataLineLimitExceeded,
            message: 'An SSE frame exceeds the configured data-line limit.',
          );
        }
        _retain(encodedByteCount);
        _dataLines.add(value);
      case 'retry':
        final milliseconds = _nonNegativeDecimal(value);
        if (milliseconds != null) {
          _retain(encodedByteCount);
          _retry = Duration(milliseconds: milliseconds);
        }
    }
    return null;
  }

  SseEvent? flush() {
    if (_id == null &&
        _event == null &&
        _retry == null &&
        _dataLines.isEmpty &&
        _commentLines.isEmpty) {
      _frameBytes = 0;
      return null;
    }
    final result = SseEvent(
      id: _id,
      event: _event,
      retry: _retry,
      data: _dataLines.isEmpty ? null : _dataLines.join('\n'),
      comment: _commentLines.isEmpty ? null : _commentLines.join('\n'),
    );
    _id = null;
    _event = null;
    _retry = null;
    _dataLines.clear();
    _commentLines.clear();
    _frameBytes = 0;
    return result;
  }

  void _retain(int encodedByteCount) {
    final next = _frameBytes + encodedByteCount + 1;
    if (next > limits.maxFrameBytes) {
      throw const SseDecodeException(
        code: SseDecodeErrorCode.frameTooLarge,
        message: 'An SSE frame exceeds the configured byte limit.',
      );
    }
    _frameBytes = next;
  }
}

({String value, int encodedByteCount}) _decodeLine(Uint8List bytes) {
  try {
    return (value: utf8.decode(bytes, allowMalformed: false), encodedByteCount: bytes.length);
  } on FormatException {
    throw const SseDecodeException(
      code: SseDecodeErrorCode.invalidUtf8,
      message: 'The SSE stream contains invalid UTF-8.',
    );
  }
}

int? _nonNegativeDecimal(String value) {
  if (value.isEmpty) return null;
  for (final codeUnit in value.codeUnits) {
    if (codeUnit < 0x30 || codeUnit > 0x39) return null;
  }
  return int.tryParse(value);
}
