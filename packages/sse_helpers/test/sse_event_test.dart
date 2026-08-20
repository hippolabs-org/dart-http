import 'package:sse_helpers/sse_helpers.dart';
import 'package:test/test.dart';

void main() {
  group('SseEvent.encode', () {
    test('encodes every SSE field in wire order', () {
      const event = SseEvent(
        comment: 'keep-alive',
        id: '42',
        event: 'message',
        retry: Duration(milliseconds: 1500),
        data: 'first\nsecond',
      );

      expect(
        event.encode(),
        ': keep-alive\n'
        'id: 42\n'
        'event: message\n'
        'retry: 1500\n'
        'data: first\n'
        'data: second\n'
        '\n',
      );
    });

    test('normalizes line endings in multiline fields', () {
      const event = SseEvent(comment: 'one\r\ntwo', data: 'three\rfour');

      expect(event.encode(), ': one\n: two\ndata: three\ndata: four\n\n');
    });
  });
}
