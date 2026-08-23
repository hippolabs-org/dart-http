import 'raw_response.dart';

/// One HTTP `Range` request using the `bytes` unit.
///
/// Multipart ranges are intentionally unsupported. [parse] throws a
/// [FormatException] when the header is malformed or contains multiple ranges.
final class HttpByteRange {
  const HttpByteRange.closed(int start, int end)
    : start = start,
      end = end,
      suffixLength = null,
      assert(start >= 0),
      assert(end >= start);

  const HttpByteRange.from(int start)
    : start = start,
      end = null,
      suffixLength = null,
      assert(start >= 0);

  const HttpByteRange.suffix(int suffixLength)
    : start = null,
      end = null,
      suffixLength = suffixLength,
      assert(suffixLength > 0);

  final int? start;
  final int? end;
  final int? suffixLength;

  /// Parses a single `bytes` range, for example `bytes=0-1023`,
  /// `bytes=1024-`, or `bytes=-1024`.
  factory HttpByteRange.parse(String value) {
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(value.trim());
    if (match == null || value.contains(',')) {
      throw FormatException('Expected one HTTP bytes range.', value);
    }

    final first = match.group(1)!;
    final second = match.group(2)!;
    if (first.isEmpty && second.isEmpty) {
      throw FormatException('A byte range must include a boundary.', value);
    }

    if (first.isEmpty) {
      final suffixLength = int.tryParse(second);
      if (suffixLength == null || suffixLength <= 0) {
        throw FormatException('Invalid byte-range suffix length.', value);
      }
      return HttpByteRange.suffix(suffixLength);
    }

    final start = int.tryParse(first);
    if (start == null) {
      throw FormatException('Invalid byte-range start.', value);
    }
    if (second.isEmpty) {
      return HttpByteRange.from(start);
    }

    final end = int.tryParse(second);
    if (end == null || end < start) {
      throw FormatException('Invalid byte-range end.', value);
    }
    return HttpByteRange.closed(start, end);
  }

  /// The normalized value suitable for an outgoing `Range` header.
  String get headerValue {
    if (suffixLength case final suffixLength?) {
      return 'bytes=-$suffixLength';
    }
    return 'bytes=$start-${end ?? ''}';
  }

  /// Resolves this request against a resource of [totalLength] bytes.
  ///
  /// Returns `null` when the range is syntactically valid but unsatisfiable.
  HttpByteRangeSelection? resolve(int totalLength) {
    if (totalLength < 0) {
      throw ArgumentError.value(totalLength, 'totalLength', 'Must be >= 0.');
    }
    if (totalLength == 0) return null;

    if (suffixLength case final suffixLength?) {
      final length = suffixLength > totalLength ? totalLength : suffixLength;
      return HttpByteRangeSelection(
        start: totalLength - length,
        end: totalLength - 1,
        totalLength: totalLength,
      );
    }

    final rangeStart = start!;
    if (rangeStart >= totalLength) return null;
    final requestedEnd = end ?? totalLength - 1;
    return HttpByteRangeSelection(
      start: rangeStart,
      end: requestedEnd >= totalLength ? totalLength - 1 : requestedEnd,
      totalLength: totalLength,
    );
  }

  /// Headers for a `416 Range Not Satisfiable` response.
  static List<HttpHeader> unsatisfiedHeaders(int totalLength) {
    if (totalLength < 0) {
      throw ArgumentError.value(totalLength, 'totalLength', 'Must be >= 0.');
    }
    return <HttpHeader>[
      const HttpHeader('Accept-Ranges', 'bytes'),
      HttpHeader('Content-Range', 'bytes */$totalLength'),
    ];
  }
}

/// A satisfiable inclusive byte range resolved against a resource length.
final class HttpByteRangeSelection {
  const HttpByteRangeSelection({required this.start, required this.end, required this.totalLength})
    : assert(start >= 0),
      assert(end >= start),
      assert(end < totalLength);

  final int start;
  final int end;
  final int totalLength;

  int get contentLength => end - start + 1;

  String get contentRangeHeaderValue => 'bytes $start-$end/$totalLength';

  List<HttpHeader> get responseHeaders => <HttpHeader>[
    const HttpHeader('Accept-Ranges', 'bytes'),
    HttpHeader('Content-Range', contentRangeHeaderValue),
  ];
}
