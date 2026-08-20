import 'dart:convert';

import 'package:sse_helpers/sse_helpers.dart';
import 'package:test/test.dart';

void main() {
  group('decodeSseEvents', () {
    test('decodes fragmented fields and multiline data', () async {
      final bytes = utf8.encode('event: message\nid: 7\ndata: first\ndata: second\n\n');
      final events = await decodeSseEvents(_oneByteChunks(bytes)).toList();

      expect(events, hasLength(1));
      expect(events.single.event, 'message');
      expect(events.single.id, '7');
      expect(events.single.data, 'first\nsecond');
    });

    test('decodes fragmented multibyte UTF-8', () async {
      final events = await decodeSseEvents(_oneByteChunks(utf8.encode('data: Grüße 👋\n\n')))
          .toList();

      expect(events.single.data, 'Grüße 👋');
    });

    test('supports BOM and LF, CRLF, and CR line endings', () async {
      final events = await decodeSseEvents(
        Stream<List<int>>.value(utf8.encode('\uFEFFdata: lf\n\ndata: crlf\r\n\r\ndata: cr\r\r')),
      ).toList();

      expect(events.map((event) => event.data), ['lf', 'crlf', 'cr']);
    });

    test('preserves comments, valid retry hints, and empty field values', () async {
      final events = await _decode(': first\n:second\nid\nevent\nretry: 1500\ndata\n\n');

      expect(events.single.comment, 'first\nsecond');
      expect(events.single.id, '');
      expect(events.single.event, '');
      expect(events.single.retry, const Duration(milliseconds: 1500));
      expect(events.single.data, '');
    });

    test('ignores unknown fields, invalid retry hints, and IDs containing null', () async {
      final events = await _decode(
        'unknown: value\nretry: -1\nretry: +2\nretry: nope\nid: bad\u0000id\ndata: kept\n\n',
      );

      expect(events.single.id, isNull);
      expect(events.single.retry, isNull);
      expect(events.single.data, 'kept');
    });

    test('uses the last singular field and flushes at end of input', () async {
      final events = await _decode('event: first\nevent: last\nid: 1\nid: 2\ndata: value');

      expect(events.single.event, 'last');
      expect(events.single.id, '2');
      expect(events.single.data, 'value');
    });

    test('can be used directly as a stream transformer', () async {
      final events = await Stream<List<int>>.value(utf8.encode('data: transformed\n\n'))
          .transform(const SseDecoder())
          .toList();

      expect(events.single, isA<SseEvent>());
      expect(events.single.data, 'transformed');
    });

    test('rejects values outside the byte range', () async {
      await expectLater(
        decodeSseEvents(Stream<List<int>>.value(<int>[256])).drain<void>(),
        throwsSseCode(SseDecodeErrorCode.invalidByte),
      );
    });

    test('rejects malformed UTF-8', () async {
      await expectLater(
        decodeSseEvents(Stream<List<int>>.value(<int>[0xc3, 0x28, 0x0a])).drain<void>(),
        throwsSseCode(SseDecodeErrorCode.invalidUtf8),
      );
    });

    test('enforces the line byte limit', () async {
      await expectLater(
        decodeSseEvents(
          Stream<List<int>>.value(utf8.encode('data: x\n')),
          limits: const SseDecodeLimits(maxLineBytes: 6),
        ).drain<void>(),
        throwsSseCode(SseDecodeErrorCode.lineTooLarge),
      );
    });

    test('enforces the retained frame byte limit', () async {
      await expectLater(
        decodeSseEvents(
          Stream<List<int>>.value(utf8.encode('data: one\ndata: two\n\n')),
          limits: const SseDecodeLimits(maxFrameBytes: 15),
        ).drain<void>(),
        throwsSseCode(SseDecodeErrorCode.frameTooLarge),
      );
    });

    test('enforces the data-line limit', () async {
      await expectLater(
        decodeSseEvents(
          Stream<List<int>>.value(utf8.encode('data: one\ndata: two\n\n')),
          limits: const SseDecodeLimits(maxDataLines: 1),
        ).drain<void>(),
        throwsSseCode(SseDecodeErrorCode.dataLineLimitExceeded),
      );
    });

    test('enforces the encoded event-name limit', () async {
      await expectLater(
        decodeSseEvents(
          Stream<List<int>>.value(utf8.encode('event: Grüße\n\n')),
          limits: const SseDecodeLimits(maxEventNameBytes: 5),
        ).drain<void>(),
        throwsSseCode(SseDecodeErrorCode.eventNameTooLarge),
      );
    });

    test('validates configured limits', () async {
      await expectLater(
        decodeSseEvents(
          const Stream<List<int>>.empty(),
          limits: const SseDecodeLimits(maxLineBytes: 0),
        ).drain<void>(),
        throwsArgumentError,
      );
    });
  });
}

Stream<List<int>> _oneByteChunks(List<int> bytes) =>
    Stream<List<int>>.fromIterable(bytes.map((byte) => <int>[byte]));

Future<List<SseEvent>> _decode(String source) =>
    decodeSseEvents(Stream<List<int>>.value(utf8.encode(source))).toList();

Matcher throwsSseCode(SseDecodeErrorCode code) =>
    throwsA(isA<SseDecodeException>().having((error) => error.code, 'code', code));
