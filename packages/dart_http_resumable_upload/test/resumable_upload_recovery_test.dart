import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_http_core/dart_http_core.dart';
import 'package:dart_http_resumable_upload/dart_http_resumable_upload.dart';
import 'package:test/test.dart';

void main() {
  test('source reads do not advance confirmed or transport progress', () async {
    final events = <ResumableUploadEvent>[];
    final transport = _RouterTransport(
      onBeforeAppend: (request) {
        expect(events.where((e) => e.type == ResumableUploadEventType.preparing), isNotEmpty);
        expect(events.last.fraction, 0);
        expect(events.last.transportFraction, isNull);
        request.onUploadProgress!(
          const DartHttpClientUploadProgress(
            bytes: 2,
            totalBytes: 4,
            measurement: DartHttpClientUploadMeasurement.transmitted,
          ),
        );
        expect(events.last.transportFraction, .5);
        expect(events.last.fraction, 0);
      },
    );
    final result = await _client(transport)
        .start(creationUri: _uri, source: _source(), onEvent: events.add);
    expect(result.checkpoint.offset, 4);
    expect(events.last.type, ResumableUploadEventType.completed);
  });

  test('server offset-mismatch problem triggers HEAD and resumes confirmed bytes', () async {
    final transport = _RouterTransport(staleFirstAppend: true);
    final result = await _client(transport).start(creationUri: _uri, source: _source());
    expect(transport.heads, 1);
    expect(transport.patches, 2);
    expect(result.checkpoint.complete, isTrue);
    expect(await transport.store.bytesFor('one'), [1, 2, 3, 4]);
  });

  test('arbitrary HTTP 400 is not retried', () async {
    final transport = _RouterTransport(rejectAppend: true);
    await expectLater(
      _client(transport).start(creationUri: _uri, source: _source()),
      throwsA(isA<ResumableUploadRejectedException>()),
    );
    expect(transport.heads, 0);
    expect(transport.patches, 1);
  });

  test('lost final append response recovers finalization and its result', () async {
    final transport = _RouterTransport(loseAppendResponse: true);
    final result = await _client(transport).start(creationUri: _uri, source: _source());
    expect(transport.heads, 1);
    expect(transport.patches, 1);
    expect(transport.callbackCalls, 1);
    expect(jsonDecode(result.response.body), {'object_id': 'one'});
  });

  test('lost finalization response replays cached success without side effects', () async {
    final transport = _RouterTransport(loseFinalizationResponse: true);
    final result = await _client(transport).start(creationUri: _uri, source: _source());
    expect(transport.finalizations, 2);
    expect(transport.callbackCalls, 1);
    expect(transport.patches, 1);
    expect(jsonDecode(result.response.body), {'object_id': 'one'});
  });

  test('a 5xx after a committed finalization retries into the replayed result', () async {
    // Finalization is idempotent on the server: it is keyed by the upload and
    // replays the first successful response, so the client may retry an
    // ambiguous failure without repeating application side effects.
    final transport = _RouterTransport(failCommittedFinalizationWith503: true);
    final result = await _client(transport).start(creationUri: _uri, source: _source());
    expect(transport.finalizations, 2);
    expect(transport.callbackCalls, 1);
    expect(result.response.status, 200);
    expect(jsonDecode(result.response.body), {'object_id': 'one'});
  });

  test('finalization failure retries without uploading bytes again', () async {
    final transport = _RouterTransport(callbackFailures: 1);
    final events = <ResumableUploadEvent>[];
    await _client(transport).start(creationUri: _uri, source: _source(), onEvent: events.add);
    expect(transport.callbackCalls, 2);
    expect(transport.patches, 1);
    expect(events.where((e) => e.type == ResumableUploadEventType.finalizing), hasLength(1));
  });

  test('finalization can resume from a complete checkpoint after retry exhaustion', () async {
    final transport = _RouterTransport(callbackFailures: 10);
    final client = _client(transport);
    ResumableUploadCheckpoint? checkpoint;
    await expectLater(
      client.start(
        creationUri: _uri,
        source: _source(),
        onCheckpoint: (value) => checkpoint = value,
      ),
      throwsA(isA<ResumableUploadFinalizationException>()),
    );
    expect(checkpoint!.complete, isTrue);
    transport.callbackFailures = 0;
    final result = await client.resume(checkpoint: checkpoint!, source: _source());
    expect(result.response.status, 200);
    expect(transport.patches, 1);
  });

  test('HTTP failure with Upload-Complete does not emit successful completion', () async {
    final transport = _RouterTransport(errorOnCompletedAppend: true);
    final events = <ResumableUploadEvent>[];
    await expectLater(
      _client(transport).start(creationUri: _uri, source: _source(), onEvent: events.add),
      throwsA(isA<ResumableUploadFinalizationException>()),
    );
    expect(events.where((e) => e.type == ResumableUploadEventType.completed), isEmpty);
  });

  test('finalization recovery does not require access to the source file', () async {
    final transport = _RouterTransport(callbackFailures: 10);
    ResumableUploadCheckpoint? checkpoint;
    final client = _client(transport);
    await expectLater(
      client.start(
        creationUri: _uri,
        source: _source(),
        onCheckpoint: (value) => checkpoint = value,
      ),
      throwsA(isA<ResumableUploadFinalizationException>()),
    );
    transport.callbackFailures = 0;
    final result = await client.finalize(checkpoint: checkpoint!);
    expect(jsonDecode(result.response.body), {'object_id': 'one'});
    expect(transport.patches, 1);
  });

  test('late transport callbacks cannot advance completed progress', () async {
    void Function(DartHttpClientUploadProgress)? lateProgress;
    final transport = _RouterTransport(
      onBeforeAppend: (request) => lateProgress = request.onUploadProgress,
    );
    final events = <ResumableUploadEvent>[];
    await _client(transport).start(creationUri: _uri, source: _source(), onEvent: events.add);
    final count = events.length;
    lateProgress!(
      const DartHttpClientUploadProgress(
        bytes: 4,
        measurement: DartHttpClientUploadMeasurement.transmitted,
      ),
    );
    expect(events.length, count);
  });

  test('retry discards transport progress and uses the authoritative checkpoint', () async {
    final events = <ResumableUploadEvent>[];
    final transport = _RouterTransport(
      staleFirstAppend: true,
      onBeforeAppend: (request) {
        request.onUploadProgress!(
          DartHttpClientUploadProgress(
            bytes: request.bodyStreamLength!,
            measurement: DartHttpClientUploadMeasurement.transmitted,
          ),
        );
      },
    );
    await _client(transport).start(creationUri: _uri, source: _source(), onEvent: events.add);
    final retry = events.firstWhere((e) => e.type == ResumableUploadEventType.waitingToRetry);
    expect(retry.fraction, 0);
    expect(retry.transportFraction, isNull);
    final checkpoints = events.where((e) => e.type == ResumableUploadEventType.checkpoint);
    expect(checkpoints.map((e) => e.checkpoint!.offset), [0, 2, 4]);
  });

  test('a throwing completion callback remains retryable', () async {
    final store = InMemoryResumableUploadStore(idGenerator: () => 'one');
    await store.create(length: 0, metadata: {});
    await store.append(
      id: 'one',
      expectedOffset: 0,
      content: ResumableUploadContent.buffered(const Stream.empty(), length: 0),
      complete: true,
    );
    await expectLater(
      store.finalize('one', () => throw StateError('transaction failed')),
      throwsStateError,
    );
    final result = await store.finalize(
      'one',
      () => RawResponse.json(status: 200, body: {'id': 'one'}),
    );
    expect(result.status, 200);
  });

  test('pause interrupts retry backoff without waiting for its timer', () async {
    final abort = Completer<void>();
    final delayStarted = Completer<void>();
    final releaseDelay = Completer<void>();
    final transport = _RouterTransport(staleFirstAppend: true);
    final client = ResumableUploadClient(
      transport: transport,
      delay: (_) {
        delayStarted.complete();
        return releaseDelay.future;
      },
    );
    final result = client.start(creationUri: _uri, source: _source(), abortTrigger: abort.future);
    final paused = expectLater(result, throwsA(isA<ResumableUploadPausedException>()));
    await delayStarted.future;
    abort.complete();
    await paused.timeout(const Duration(seconds: 1));
    releaseDelay.complete();
    expect(transport.heads, 0);
  });

  test('concurrent finalizers serialize and share the successful response', () async {
    final store = InMemoryResumableUploadStore(idGenerator: () => 'one');
    await store.create(length: 0, metadata: {});
    await store.append(
      id: 'one',
      expectedOffset: 0,
      content: ResumableUploadContent.buffered(const Stream.empty(), length: 0),
      complete: true,
    );
    var calls = 0;
    final gate = Completer<void>();
    Future<RawResponse> callback() async {
      calls++;
      await gate.future;
      return RawResponse.json(status: 200, body: {'id': 'one'});
    }

    final first = store.finalize('one', callback);
    final second = store.finalize('one', callback);
    gate.complete();
    final results = await Future.wait([first, second]);
    expect(calls, 1);
    expect(results[0], same(results[1]));
  });
}

final _uri = Uri.parse('https://example.test/uploads');
ResumableUploadSource _source() => ResumableUploadSource.bytes([1, 2, 3, 4]);
ResumableUploadClient _client(HttpClientTransport transport) => ResumableUploadClient(
  transport: transport,
  retryPolicy: const ResumableUploadRetryPolicy(maxRetries: 1, initialDelay: Duration.zero),
  delay: (_) async {},
);

class _RouterTransport implements HttpClientTransport {
  _RouterTransport({
    this.staleFirstAppend = false,
    this.rejectAppend = false,
    this.loseAppendResponse = false,
    this.loseFinalizationResponse = false,
    this.failCommittedFinalizationWith503 = false,
    this.callbackFailures = 0,
    this.errorOnCompletedAppend = false,
    this.onBeforeAppend,
  }) {
    mountResumableUploadRoutes<void>(
      router,
      path: '/uploads',
      store: store,
      locationFor: (_, r) => _uri.replace(path: '/uploads/${r.id}'),
      onCompleted: (_, r) {
        callbackCalls++;
        if (callbackFailures > 0) {
          callbackFailures--;
          return RawResponse.json(status: 503, body: {'error': 'retry'});
        }
        return RawResponse.json(status: 200, body: {'object_id': r.id});
      },
    );
  }
  final router = Router<void>();
  final store = InMemoryResumableUploadStore(idGenerator: () => 'one');
  final bool staleFirstAppend,
      rejectAppend,
      loseAppendResponse,
      loseFinalizationResponse,
      failCommittedFinalizationWith503,
      errorOnCompletedAppend;
  final void Function(DartHttpClientRequest)? onBeforeAppend;
  int callbackFailures;
  int patches = 0, heads = 0, finalizations = 0, callbackCalls = 0;

  @override
  Future<DartHttpClientResponse> send(DartHttpClientRequest request) async {
    final bytes = <int>[];
    if (request.bodyStream case final stream?) {
      await for (final chunk in stream) {
        bytes.addAll(chunk);
      }
    }
    if (request.method == HttpMethod.patch) {
      patches++;
      onBeforeAppend?.call(request);
      if (rejectAppend) {
        return const DartHttpClientResponse(status: 400, contentType: '', body: '{}');
      }
      if (staleFirstAppend && patches == 1) {
        await store.append(
          id: 'one',
          expectedOffset: 0,
          content: ResumableUploadContent.buffered(Stream.value(bytes.take(2).toList()), length: 2),
          complete: false,
        );
      }
    }
    if (request.method == HttpMethod.head) heads++;
    final isFinalize = request.uri.path.endsWith('/complete');
    if (isFinalize) finalizations++;
    final route =
        router.routeRegistry.registrations
                .firstWhere(
                  (r) =>
                      r.httpMethod == request.method &&
                      (isFinalize
                          ? (r.httpPath?.endsWith('/complete') ?? false)
                          : !(r.httpPath?.endsWith('/complete') ?? false)),
                )
                .route
            as HttpRouteDefinition<void, RawResponse>;
    final raw = await route.handle(
      RequestContext<void>(
        services: null,
        req: RequestInput(
          paramsMap: {'uploadId': 'one'},
          headersMap: request.headers,
          body: request.method == HttpMethod.patch ? Uint8List.fromList(bytes) : null,
        ),
      ),
    );
    if ((loseAppendResponse && request.method == HttpMethod.patch && patches == 1) ||
        (loseFinalizationResponse && isFinalize && finalizations == 1)) {
      throw StateError('response lost');
    }
    if (failCommittedFinalizationWith503 && isFinalize && finalizations == 1) {
      return const DartHttpClientResponse(status: 503, contentType: '', body: '');
    }
    return DartHttpClientResponse(
      status: errorOnCompletedAppend && request.method == HttpMethod.patch ? 500 : raw.status,
      contentType: raw.contentType,
      headers: {for (final h in raw.headers) h.name.toLowerCase(): h.value},
      body: raw.body is String ? raw.body as String : jsonEncode(raw.body),
    );
  }

  @override
  Future<DartHttpClientStreamedResponse> sendStream(DartHttpClientRequest request) =>
      throw UnimplementedError();
}
