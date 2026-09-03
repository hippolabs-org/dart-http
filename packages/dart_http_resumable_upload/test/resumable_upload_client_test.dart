import 'dart:typed_data';

import 'package:dart_http_core/dart_http_core.dart';
import 'package:dart_http_resumable_upload/dart_http_resumable_upload.dart';
import 'package:test/test.dart';

void main() {
  test('recovers the confirmed offset after an interrupted append', () async {
    final transport = _InterruptedUploadTransport(headFailures: 1);
    final checkpoints = <ResumableUploadCheckpoint>[];
    final events = <ResumableUploadEvent>[];
    final client = ResumableUploadClient(
      transport: transport,
      chunkSize: 4,
      retryPolicy: const ResumableUploadRetryPolicy(
        maxRetries: 2,
        initialDelay: Duration.zero,
        maxDelay: Duration.zero,
      ),
      delay: (_) async {},
    );

    final result = await client.start(
      creationUri: Uri.parse('https://example.test/uploads'),
      source: ResumableUploadSource.bytes(List<int>.generate(10, (index) => index)),
      onCheckpoint: checkpoints.add,
      onEvent: events.add,
    );

    expect(transport.acceptedBytes, List<int>.generate(10, (index) => index));
    expect(transport.patchRequests, 3);
    expect(transport.headRequests, 2);
    expect(checkpoints.map((value) => value.offset), [0, 2, 6, 10]);
    expect(result.checkpoint.complete, isTrue);
    expect(result.checkpoint.offset, 10);
    expect(
      events.where((event) => event.type == ResumableUploadEventType.waitingToRetry),
      hasLength(2),
    );
  });

  test('resumes a serialized checkpoint from the authoritative server offset', () async {
    final transport = _InterruptedUploadTransport(
      acceptedBytes: <int>[0, 1, 2, 3],
      interruptFirstPatch: false,
    );
    final checkpoint = ResumableUploadCheckpoint.fromJson(
      ResumableUploadCheckpoint(
        uploadUri: Uri.parse('https://example.test/uploads/upload-1'),
        offset: 2,
        totalBytes: 10,
      ).toJson(),
    );
    final client = ResumableUploadClient(transport: transport, chunkSize: 4);

    final result = await client.resume(
      checkpoint: checkpoint,
      source: ResumableUploadSource.bytes(List<int>.generate(10, (index) => index)),
    );

    expect(transport.acceptedBytes, List<int>.generate(10, (index) => index));
    expect(result.checkpoint.offset, 10);
    expect(result.checkpoint.complete, isTrue);
  });

  test('honors the server maximum append size', () async {
    final transport = _InterruptedUploadTransport(interruptFirstPatch: false, maxAppendSize: 3);
    final client = ResumableUploadClient(transport: transport, chunkSize: 8);

    await client.start(
      creationUri: Uri.parse('https://example.test/uploads'),
      source: ResumableUploadSource.bytes(List<int>.generate(10, (index) => index)),
    );

    expect(transport.patchRequests, 4);
  });
}

final class _InterruptedUploadTransport implements HttpClientTransport {
  _InterruptedUploadTransport({
    List<int>? acceptedBytes,
    this.interruptFirstPatch = true,
    int headFailures = 0,
    this.maxAppendSize,
  }) : acceptedBytes = <int>[...?acceptedBytes],
       _remainingHeadFailures = headFailures;

  final List<int> acceptedBytes;
  final bool interruptFirstPatch;
  final int? maxAppendSize;
  var _interrupted = false;
  var totalBytes = 10;
  var patchRequests = 0;
  var headRequests = 0;
  var _remainingHeadFailures = 0;

  @override
  Future<DartHttpClientResponse> send(DartHttpClientRequest request) async {
    return switch (request.method) {
      HttpMethod.post => _create(request),
      HttpMethod.head => _head(),
      HttpMethod.patch => _append(request),
      HttpMethod.delete => _response(status: 204),
      _ => throw UnsupportedError('Unexpected method ${request.method}.'),
    };
  }

  DartHttpClientResponse _create(DartHttpClientRequest request) {
    totalBytes = int.parse(request.headers[ResumableUploadProtocol.lengthHeader]!);
    return _response(
      status: 201,
      headers: <String, String>{'location': '/uploads/upload-1', ..._stateHeaders(complete: false)},
    );
  }

  DartHttpClientResponse _head() {
    headRequests += 1;
    if (_remainingHeadFailures > 0) {
      _remainingHeadFailures -= 1;
      throw StateError('offset inspection interrupted');
    }
    return _response(
      status: 204,
      headers: _stateHeaders(complete: acceptedBytes.length == totalBytes),
    );
  }

  Future<DartHttpClientResponse> _append(DartHttpClientRequest request) async {
    patchRequests += 1;
    final expectedOffset = int.parse(request.headers[ResumableUploadProtocol.offsetHeader]!);
    if (expectedOffset != acceptedBytes.length) {
      return _response(status: 409, headers: _stateHeaders(complete: false));
    }
    final bytes = <int>[];
    await for (final chunk in request.bodyStream!) {
      bytes.addAll(chunk);
    }
    if (interruptFirstPatch && !_interrupted) {
      _interrupted = true;
      acceptedBytes.addAll(bytes.take(2));
      throw StateError('connection interrupted');
    }
    acceptedBytes.addAll(bytes);
    final requestedComplete = ResumableUploadProtocol.parseBoolean(
      request.headers[ResumableUploadProtocol.completeHeader],
    )!;
    final complete = requestedComplete && acceptedBytes.length == totalBytes;
    return _response(
      status: complete ? 200 : 204,
      headers: _stateHeaders(complete: complete),
    );
  }

  Map<String, String> _stateHeaders({required bool complete}) => <String, String>{
    ResumableUploadProtocol.offsetHeader: '${acceptedBytes.length}',
    ResumableUploadProtocol.lengthHeader: '$totalBytes',
    ResumableUploadProtocol.completeHeader: ResumableUploadProtocol.encodeBoolean(complete),
    if (maxAppendSize case final value?)
      ResumableUploadProtocol.limitHeader: 'max-append-size=$value',
  };

  static DartHttpClientResponse _response({
    required int status,
    Map<String, String> headers = const <String, String>{},
  }) {
    return DartHttpClientResponse(
      status: status,
      contentType: 'text/plain; charset=utf-8',
      headers: headers,
    );
  }

  @override
  Future<DartHttpClientStreamedResponse> sendStream(DartHttpClientRequest request) async {
    final response = await send(request);
    return DartHttpClientStreamedResponse(
      status: response.status,
      contentType: response.contentType,
      headers: response.headers,
      bodyStream: Stream<List<int>>.value(Uint8List(0)),
    );
  }
}
