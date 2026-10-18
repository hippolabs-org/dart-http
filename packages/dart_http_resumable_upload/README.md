# dart_http_resumable_upload

Transport-neutral client and server helpers for resumable HTTP uploads.

The package implements the careful-creation flow from
`draft-ietf-httpbis-resumable-upload-12`, draft interoperability version 9:

1. Create an empty upload resource.
2. Append bounded chunks with `PATCH application/partial-upload` (8 MiB by default).
3. Recover the authoritative durable offset with `HEAD` after interruption.
4. Complete or cancel the upload resource.

Applications own authentication, durable storage, upload metadata, source file
identity, and processing after completion. The package owns protocol headers,
offset validation, retry coordination, progress semantics, and route wiring.

## Client and file sources

```dart
final client = ResumableUploadClient(transport: transport);
final result = await client.start(
  creationUri: Uri.parse('https://api.example.test/uploads'),
  source: CallbackResumableUploadSource(
    length: await file.length(),
    onOpenRead: ({required offset, required length}) =>
        file.openRead(offset, offset + length),
  ),
  onCheckpoint: persistCheckpoint,
  onEvent: showProgress,
);
```

Use bounded, repeatable file ranges for large files. `ResumableUploadSource.bytes`
copies the complete input and is intended for small in-memory payloads. A web
file adapter should slice the browser File/Blob rather than read the whole file.
Persist `ResumableUploadCheckpoint.toJson()` and resume it with the same source:

```dart
final result = await client.resume(
  checkpoint: ResumableUploadCheckpoint.fromJson(savedJson),
  source: reopenedSource,
);
```

Applications must verify source identity when reopening a file; matching length
alone is insufficient. Reload recovery may require the user to select the file
again. The client re-inspects the server offset before resuming. An explicit
`abortTrigger` pauses a transfer without deleting the server resource; `cancel`
sends DELETE and discards it. Retry delays are interruptible.

## Accurate progress

`ResumableUploadEvent` deliberately separates three measurements:

- `preparedOffset`: bytes read from the source. Preparation is not transmission.
- `transportOffset` and `transportMeasurement`: in-flight bytes measured by the
  HTTP transport for the current attempt, added to the confirmed offset.
- `checkpoint.offset`: bytes confirmed by the server. Only this offset is durable
  and safe to use when resuming.

`event.fraction` is confirmed progress. `event.transportFraction` is optional
in-flight progress. Transports without a measurement leave it null; use confirmed
checkpoints as the fallback. The old `optimisticOffset` is deprecated and no longer
drives `fraction`.

`dart_http_client` uses browser XHR upload events for buffered-response requests
with an upload callback (`transmitted`). `dart_http_native_client` measures frames
when the native HTTP engine polls its body (`transportConsumed`), not when Dart
queues bytes. Native socket/TLS buffering can still run ahead of the peer. Neither
measurement proves durable receipt. No transport fabricates progress from source
reads or timers.

Discard in-flight progress on `waitingToRetry`/`inspecting` and use the recovered
checkpoint; retransmitted bytes must not count twice. In-flight progress can reach
100% before acknowledgment. Show "Confirming upload" until the final checkpoint,
and "Finalizing" while the application result is being committed. Do not label a
recording ready while transcription is still running.

## Server and durable finalization

```dart
mountResumableUploadRoutes(
  router,
  path: '/uploads',
  store: uploadStore,
  locationFor: (context, resource) =>
      Uri.parse('https://api.example.test/uploads/${resource.id}'),
  guards: uploadGuards,
  metadataFor: (context) => {'owner_id': context.services.user.id},
  onCompleted: (context, resource) async {
    final object = await finalizeAndEnqueueProcessing(resource);
    return RawResponse.json(status: 200, body: {'id': object.id});
  },
);
```

`onCompleted` requires a `ResumableUploadFinalizationStore`. Uploading the final
chunk only completes the bytes. The optional Dart HTTP extension header
`Upload-Finalization-Location` advertises `POST /uploads/<id>/complete`; the client
calls this endpoint and emits `finalizing` before emitting `completed`.

The store's `finalize` operation must serialize with append/cancel and durably
cache successful responses. A replay returns the cached response. Exceptions and
unsuccessful responses remain retryable. The callback must itself be idempotent:
a process can crash after side effects but before caching the result. Use the
upload ID as the application idempotency key, and enqueue long-running processing
rather than awaiting transcription/indexing inside the callback.

A lost final PATCH response is recovered through HEAD. A lost finalization response
is recovered by replaying the POST. After retry exhaustion,
`ResumableUploadFinalizationException` retains a complete checkpoint; `resume`
retries finalization without retransmitting bytes. Alternatively,
`client.finalize(checkpoint: checkpoint)` recovers the result without requiring
access to the source file. HTTP failures carrying
`Upload-Complete: ?1` do not emit a successful `completed` event. Finalization
locations must use the upload origin so credentials are not forwarded elsewhere.

`InMemoryResumableUploadStore` implements this contract for tests/examples only.
Production stores must persist offsets, completion state, cached responses, and
expiration, with atomic per-resource append/finalization operations. Guards must
check ownership for every resource operation, including finalization and DELETE.
The package does not supply a production database or object-storage adapter.

For cross-origin browser requests, configure OPTIONS and allow POST/PATCH/HEAD/
DELETE plus the protocol/auth headers. Expose `Location`, `Upload-Offset`,
`Upload-Length`, `Upload-Complete`, `Upload-Limit`, and
`Upload-Finalization-Location` in CORS responses.

## Native server streaming

Plain `ResumableUploadStore` implementations use bounded buffered PATCH bodies.
Implement `NativeResumableUploadStore` to receive a capacity-one Native Exchange
stream directly from the runtime:

```dart
final incoming = content.nativeStream;
if (incoming is! NativeRequestBodyStream) {
  throw StateError('Expected the native Dart HTTP runtime.');
}
await nativeStorage.append(incoming.takeNative(), offset: expectedOffset);
```

The store must await native consumption and persist every accepted prefix,
reporting its exact durable offset after interruption. Dart coordinates the
operation without materializing the payload.

## Migration

- `onCompleted` now runs via the advertised finalization POST instead of inside
  the last PATCH. Implement `ResumableUploadFinalizationStore` and deploy the
  updated client and server together when adopting this callback flow.
- `fraction` now reports confirmed progress. Use `transportFraction` for measured
  in-flight movement and handle the `preparing` and `finalizing` event types.
- Native progress requires the matching native client asset (ABI 17).

## Durable server integration

Import `dart_http_resumable_upload_io.dart` for
`FileSystemResumableUploadStore(directory: Directory('/persistent/uploads'))`, then
mount it with `router.resumableUploads(path: '/uploads', store: store,
locationFor: ..., onCompleted: ...)`. The extension delegates the protocol to the
package. Product callbacks authorize metadata and promote completed payloads.
`allowCreation: false` supports applications that allocate sessions through an
existing domain API.

The store flushes bytes before committing offsets, recovers unconfirmed suffixes,
and caches successful finite completion responses. A completion callback can run
again if the process stops after its side effect but before caching its response;
make database writes and job enqueueing idempotent using the upload ID. Read the
immutable completed source through `payloadFile(id)` without loading the file
into Dart memory.

Use one store-owning isolate per process and a persistent volume shared by every
process serving the session. The filesystem must support advisory locks and
atomic rename. Invoke `deleteExpired()` periodically. Cancellation and cleanup
serialize with finalization. Lock files are retained to avoid inode races.

For cross-origin clients, configure CORS to allow the upload request headers and
expose Location, Upload-Offset, Upload-Length, Upload-Complete, Upload-Limit, and
Upload-Finalization-Location. In-flight transport progress is separate from
confirmed receipt and application processing.

Run the native HTTP large-file smoke test with:

```sh
UPLOAD_TEST_BYTES=524288000 dart test packages/dart_http_resumable_upload/test/resumable_upload_io_test.dart
```
