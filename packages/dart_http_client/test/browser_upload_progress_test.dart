@TestOn('browser')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dart_http_client/dart_http_client.dart';
import 'package:dart_http_core/dart_http_core.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  late Uri baseUri;
  late DartHttpClientTransport transport;
  setUp(() async {
    final server = spawnHybridUri('support/upload_server.dart');
    baseUri = Uri.parse(await server.stream.first as String);
    transport = DartHttpClientTransport(browserUploadWithCredentials: true);
  });
  tearDown(() => transport.close());

  test('reports browser transmission, never source preparation', () async {
    final events = <DartHttpClientUploadProgress>[];
    final firstRead = Completer<void>();
    final finishPreparing = Completer<void>();
    final bytes = Uint8List(8 * 1024 * 1024);
    final responseFuture = transport.send(
      DartHttpClientRequest(
        method: HttpMethod.patch,
        uri: baseUri.resolve('/echo'),
        headers: const {'content-type': 'application/octet-stream', 'authorization': 'Bearer test'},
        bodyStreamLength: bytes.length,
        bodyStream: () async* {
          yield Uint8List.sublistView(bytes, 0, bytes.length ~/ 2);
          firstRead.complete();
          await finishPreparing.future;
          yield Uint8List.sublistView(bytes, bytes.length ~/ 2);
        }(),
        onUploadProgress: events.add,
      ),
    );
    await firstRead.future;
    expect(events, isEmpty);
    finishPreparing.complete();
    final response = await responseFuture;
    expect(response.status, 200);
    expect(response.headers['x-received-bytes'], '${bytes.length}');
    expect(events, isNotEmpty);
    expect(events.last.bytes, bytes.length);
    expect(events.last.totalBytes, bytes.length);
    expect(
      events.every((e) => e.measurement == DartHttpClientUploadMeasurement.transmitted),
      isTrue,
    );
    expect(
      events.map((e) => e.bytes),
      orderedEquals(events.map((e) => e.bytes).toSet().toList()..sort()),
    );
  });

  test('cancels after browser progress and stops further reports', () async {
    final abort = Completer<void>();
    final events = <DartHttpClientUploadProgress>[];
    final bytes = Uint8List(32 * 1024 * 1024);
    await expectLater(
      transport.send(
        DartHttpClientRequest(
          method: HttpMethod.post,
          uri: baseUri.resolve('/slow'),
          bodyBytes: bytes,
          abortTrigger: abort.future,
          onUploadProgress: (event) {
            events.add(event);
            if (!abort.isCompleted) abort.complete();
          },
        ),
      ),
      throwsA(isA<http.RequestAbortedException>()),
    );
    expect(events, isNotEmpty);
    expect(events.last.bytes, lessThanOrEqualTo(bytes.length));
    final count = events.length;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(events.length, count);
  });

  test('closing the transport cancels a prepared upload and stops progress', () async {
    final prepared = Completer<void>();
    final release = Completer<void>();
    final events = <DartHttpClientUploadProgress>[];
    final response = transport.send(
      DartHttpClientRequest(
        method: HttpMethod.post,
        uri: baseUri.resolve('/echo'),
        bodyStream: () async* {
          prepared.complete();
          await release.future;
          yield [1];
        }(),
        onUploadProgress: events.add,
      ),
    );
    final failed = expectLater(response, throwsA(isA<http.RequestAbortedException>()));
    await prepared.future;
    transport.close();
    await failed.timeout(const Duration(seconds: 2));
    release.complete();
    expect(events, isEmpty);
  });

  test('cancels preparation promptly without emitting upload events', () async {
    final abort = Completer<void>();
    final prepared = Completer<void>();
    final release = Completer<void>();
    final events = <DartHttpClientUploadProgress>[];
    final response = transport.send(
      DartHttpClientRequest(
        method: HttpMethod.post,
        uri: baseUri.resolve('/echo'),
        abortTrigger: abort.future,
        bodyStream: () async* {
          prepared.complete();
          await release.future;
          yield [1];
        }(),
        onUploadProgress: events.add,
      ),
    );
    final failed = expectLater(response, throwsA(isA<http.RequestAbortedException>()));
    await prepared.future;
    abort.complete();
    await failed.timeout(const Duration(seconds: 2));
    release.complete();
    expect(events, isEmpty);
  });
}
