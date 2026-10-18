@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_http_native_client/dart_http_native_client.dart';
import 'package:dart_http_resumable_upload/dart_http_resumable_upload_io.dart';
import 'package:dart_http_server_runtime/dart_http_server_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('resumes disk-backed uploads over native HTTP and replays completion', () async {
    final bytes = int.parse(
      Platform.environment['UPLOAD_TEST_BYTES'] ?? '${16 * 1024 * 1024 + 17}',
    );
    const chunkSize = 8 * 1024 * 1024;
    final root = await Directory.systemTemp.createTemp('resumable-http-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}/source');
    final sink = source.openWrite();
    final block = Uint8List.fromList(List.generate(64 * 1024, (i) => i % 251));
    for (var offset = 0; offset < bytes; offset += block.length) {
      sink.add(offset + block.length <= bytes ? block : block.sublist(0, bytes - offset));
      // Awaiting each flush bounds preparation even for the 500 MiB smoke run.
      await sink.flush();
    }
    await sink.close();
    final directory = Directory('${root.path}/uploads');
    final originalStore = FileSystemResumableUploadStore(directory: directory);
    final upload = await originalStore.create(length: bytes, metadata: {'user': 'one'});
    await originalStore.append(
      id: upload.id,
      expectedOffset: 0,
      complete: false,
      content: ResumableUploadContent.buffered(source.openRead(0, chunkSize), length: chunkSize),
    );
    // Reopen from durable state, as after a process restart.
    final store = FileSystemResumableUploadStore(directory: directory);
    final app = DartHttp<void>();
    late Uri base;
    var completions = 0;
    app.resumableUploads(
      path: '/uploads',
      store: store,
      locationFor: (_, r) => base.resolve('/uploads/${r.id}'),
      onCompleted: (_, r) async {
        expect((await store.read(r.id))!.complete, isTrue);
        completions++;
        return RawResponse.json(status: 200, body: {'id': r.id});
      },
    );
    final server = await app.listen(port: 0);
    addTearDown(server.close);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    final transport = await NativeHttpClientTransport.open();
    addTearDown(transport.close);
    final client = ResumableUploadClient(transport: transport);
    var reads = 0;
    final result = await client
        .resume(
          checkpoint: ResumableUploadCheckpoint(
            uploadUri: base.resolve('/uploads/${upload.id}'),
            offset: 0,
            totalBytes: bytes,
          ),
          source: CallbackResumableUploadSource(
            length: bytes,
            onOpenRead: ({required offset, required length}) {
              expect(offset, greaterThanOrEqualTo(chunkSize));
              expect(length, lessThanOrEqualTo(chunkSize));
              reads++;
              return source.openRead(offset, offset + length);
            },
          ),
        )
        .catchError((Object error) {
          if (error is ResumableUploadRejectedException) fail(error.response.body);
          throw error;
        });
    expect(result.checkpoint.complete, isTrue);
    expect(await store.payloadFile(upload.id).length(), bytes);
    final reader = await store.payloadFile(upload.id).open();
    addTearDown(reader.close);
    for (final offset in [0, chunkSize - 13, bytes - 25]) {
      await reader.setPosition(offset);
      expect(await reader.read(25), List.generate(25, (i) => ((offset + i) % block.length) % 251));
    }
    expect(reads, greaterThan(0));
    await client.finalize(checkpoint: result.checkpoint);
    expect(completions, 1);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
