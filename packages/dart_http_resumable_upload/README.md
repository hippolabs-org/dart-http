# dart_http_resumable_upload

Transport-neutral client and server helpers for resumable HTTP uploads.

The package implements the careful-creation flow from
`draft-ietf-httpbis-resumable-upload-12`, draft interoperability version 9:

1. Create an empty upload resource.
2. Append bounded chunks with `PATCH application/partial-upload`.
3. Recover the authoritative offset with `HEAD` after interruption.
4. Complete or cancel the upload resource.

Applications own authentication, durable storage, upload metadata, and any
processing triggered after completion. The package owns protocol headers,
offset validation, retry coordination, and route wiring.

## Client

```dart
final client = ResumableUploadClient(transport: transport);
final result = await client.start(
  creationUri: Uri.parse('https://api.example.test/uploads'),
  source: ResumableUploadSource.bytes(fileBytes),
  onCheckpoint: persistCheckpoint,
  onEvent: showProgress,
);
```

Persist the emitted `ResumableUploadCheckpoint` and resume it later:

```dart
final result = await client.resume(
  checkpoint: restoredCheckpoint,
  source: reopenedSource,
);
```

## Server

```dart
mountResumableUploadRoutes(
  router,
  path: '/uploads',
  store: uploadStore,
  locationFor: (context, resource) =>
      Uri.parse('https://api.example.test/uploads/${resource.id}'),
  metadataFor: (context) => {'owner_id': context.services.user.id},
  onCompleted: (context, resource) async {
    await processUpload(resource);
    return RawResponse.json(status: 200, body: {'id': resource.id});
  },
);
```

`InMemoryResumableUploadStore` is provided for tests and examples. Production
applications should implement `ResumableUploadStore` with durable storage and
atomic per-resource append operations.

For a zero-copy native server path, implement `NativeResumableUploadStore` and
adopt the incoming runtime stream in `append`:

```dart
final incoming = content.nativeStream;
if (incoming is! NativeRequestBodyStream) {
  throw StateError('Expected the native Dart HTTP runtime.');
}
final stream = incoming.takeNative();
await nativeStorage.append(stream, offset: expectedOffset);
```

The store must await native consumption, persist every accepted prefix, and
return the resulting durable offset. Dart coordinates the operation but does
not materialize the request payload.

## Current runtime behavior

Plain `ResumableUploadStore` implementations use bounded buffered PATCH bodies.
`NativeResumableUploadStore` implementations receive a capacity-one Native
Exchange stream directly from Axum. This enables a store to preserve a durable
mid-request prefix and report its exact offset after an interruption.
