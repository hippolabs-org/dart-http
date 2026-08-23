import 'dart:async';

import 'package:dart_edge_core/dart_edge_core.dart';
import 'package:test/test.dart';

void main() {
  group('HttpByteRange', () {
    test('parses closed, open-ended, and suffix ranges', () {
      expect(HttpByteRange.parse('bytes=2-7').headerValue, 'bytes=2-7');
      expect(HttpByteRange.parse('bytes=8-').headerValue, 'bytes=8-');
      expect(HttpByteRange.parse('bytes=-4').headerValue, 'bytes=-4');
    });

    test('rejects malformed and multipart ranges', () {
      for (final value in <String>[
        'items=0-1',
        'bytes=-',
        'bytes=4-3',
        'bytes=0-1,4-5',
        'bytes=-0',
      ]) {
        expect(() => HttpByteRange.parse(value), throwsFormatException);
      }
    });

    test('resolves and clamps ranges to the resource', () {
      final closed = HttpByteRange.parse('bytes=2-99').resolve(10)!;
      expect((closed.start, closed.end, closed.contentLength), (2, 9, 8));
      expect(closed.contentRangeHeaderValue, 'bytes 2-9/10');

      final open = HttpByteRange.parse('bytes=8-').resolve(10)!;
      expect((open.start, open.end), (8, 9));

      final suffix = HttpByteRange.parse('bytes=-4').resolve(10)!;
      expect((suffix.start, suffix.end), (6, 9));

      final oversizedSuffix = HttpByteRange.parse('bytes=-50').resolve(10)!;
      expect((oversizedSuffix.start, oversizedSuffix.end), (0, 9));
    });

    test('reports syntactically valid unsatisfiable ranges', () {
      expect(HttpByteRange.parse('bytes=10-').resolve(10), isNull);
      expect(HttpByteRange.parse('bytes=-1').resolve(0), isNull);
    });
  });

  test('partial stream responses set the standard wire metadata', () {
    final range = HttpByteRange.parse('bytes=2-4').resolve(10)!;
    final response = BinaryStreamResponse.partial(
      body: const Stream<List<int>>.empty(),
      contentType: 'audio/wav',
      range: range,
    );

    expect(response.status, 206);
    expect(response.contentLength, 3);
    expect(
      {for (final header in response.headers) header.name: header.value},
      {'Accept-Ranges': 'bytes', 'Content-Range': 'bytes 2-4/10'},
    );

    final unsatisfied = RawResponse.rangeNotSatisfiable(totalLength: 10);
    expect(unsatisfied.status, 416);
    expect(
      {for (final header in unsatisfied.headers) header.name: header.value},
      {'Accept-Ranges': 'bytes', 'Content-Range': 'bytes */10'},
    );
  });
}
