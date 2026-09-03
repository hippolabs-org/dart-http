import 'package:dart_http_resumable_upload/dart_http_resumable_upload.dart';
import 'package:test/test.dart';

void main() {
  test('encodes and parses protocol values', () {
    expect(ResumableUploadProtocol.encodeBoolean(true), '?1');
    expect(ResumableUploadProtocol.encodeBoolean(false), '?0');
    expect(ResumableUploadProtocol.parseBoolean('?1'), isTrue);
    expect(ResumableUploadProtocol.parseBoolean('?0'), isFalse);
    expect(ResumableUploadProtocol.parseBoolean('true'), isNull);
    expect(ResumableUploadProtocol.parseNonNegativeInteger('42'), 42);
    expect(ResumableUploadProtocol.parseNonNegativeInteger('-1'), isNull);
  });

  test('checkpoint round-trips through JSON', () {
    final checkpoint = ResumableUploadCheckpoint(
      uploadUri: Uri.parse('https://example.test/uploads/one'),
      offset: 42,
      totalBytes: 100,
    );

    expect(ResumableUploadCheckpoint.fromJson(checkpoint.toJson()).toJson(), checkpoint.toJson());
    expect(checkpoint.fraction, .42);
  });

  test('limits use structured field dictionary syntax', () {
    const limits = ResumableUploadLimits(
      maxSize: 100,
      minSize: 4,
      minAppendSize: 2,
      maxAppendSize: 20,
      maxAge: Duration(minutes: 5),
    );

    expect(
      limits.toHeaderValue(),
      'max-size=100, min-size=4, min-append-size=2, max-append-size=20, max-age=300',
    );
    final parsed = ResumableUploadLimits.parse(limits.toHeaderValue())!;
    expect(parsed.maxSize, 100);
    expect(parsed.minSize, 4);
    expect(parsed.minAppendSize, 2);
    expect(parsed.maxAppendSize, 20);
    expect(parsed.maxAge, const Duration(minutes: 5));
    expect(ResumableUploadLimits.parse('max-append-size=wrong'), isNull);
  });
}
