import 'package:dart_http_core/dart_http_core.dart';
import 'package:test/test.dart';

void main() {
  group('DartHttpClientStreamedResponseObject', () {
    test('parses content length case-insensitively', () {
      final response = DartHttpClientStreamedResponseObject(
        status: 200,
        contentType: 'application/octet-stream',
        headers: const {'Content-Length': ' 5 '},
        bodyStream: const Stream<List<int>>.empty(),
      );

      expect(response.contentLength, 5);
    });

    test('reports progress while preserving body chunks', () async {
      final progress = <DartHttpClientDownloadProgress>[];
      final chunks = <List<int>>[
        [1, 2],
        [3, 4, 5],
      ];
      final response = DartHttpClientStreamedResponseObject(
        status: 200,
        contentType: 'application/octet-stream',
        headers: const {'content-length': '5'},
        bodyStream: Stream<List<int>>.fromIterable(chunks),
      );

      final received = await response.bodyStreamWithProgress(onProgress: progress.add).toList();

      expect(received, chunks);
      expect(progress.map((value) => value.bytesReceived), orderedEquals([2, 5]));
      expect(progress.map((value) => value.totalBytes), everyElement(5));
      expect(progress.last.fraction, 1);
    });

    test('allows callers to override missing content length', () async {
      DartHttpClientDownloadProgress? progress;
      final response = DartHttpClientStreamedResponseObject(
        status: 200,
        contentType: 'application/octet-stream',
        bodyStream: Stream<List<int>>.value([1, 2]),
      );

      await response
          .bodyStreamWithProgress(totalBytes: 4, onProgress: (value) => progress = value)
          .drain<void>();

      expect(progress?.bytesReceived, 2);
      expect(progress?.totalBytes, 4);
      expect(progress?.fraction, 0.5);
    });
  });
}
