import 'dart:async';
import 'dart:typed_data';

import 'package:dart_http_core/dart_http_core.dart';

import '../models/content.dart';
import '../models/limits.dart';
import '../protocol/resumable_upload_protocol.dart';
import 'resumable_upload_store.dart';

typedef ResumableUploadLocationBuilder<TServices> = Uri Function(
  RequestContext<TServices> context,
  ResumableUploadResource resource,
);
typedef ResumableUploadCompletionHandler<TServices> = FutureOr<RawResponse> Function(
  RequestContext<TServices> context,
  ResumableUploadResource resource,
);
typedef ResumableUploadMetadataBuilder<TServices> = FutureOr<Map<String, String>> Function(
  RequestContext<TServices> context,
);

/// Mounts careful-creation resumable upload routes at [path].
void mountResumableUploadRoutes<TServices>(
  Router<TServices> router, {
  required String path,
  required ResumableUploadStore store,
  required ResumableUploadLocationBuilder<TServices> locationFor,
  ResumableUploadCompletionHandler<TServices>? onCompleted,
  ResumableUploadMetadataBuilder<TServices>? metadataFor,
  ResumableUploadLimits limits = const ResumableUploadLimits(),
  List<Guard<TServices>> guards = const [],
  String operationIdPrefix = 'resumableUpload',
}) {
  router.options<RawResponse>(
    path,
    guards: guards,
    options: RouteOptions(
      operationId: '${operationIdPrefix}Discover',
      summary: 'Discover resumable upload support and limits.',
      success: const ResponseSpec.text(status: 204),
    ),
    handler: (context) {
      final versionError = _validateVersion(context.req);
      if (versionError != null) return versionError;
      return RawResponse.text(status: 204, headers: _limitHeaders(limits));
    },
  );

  router.post<RawResponse>(
    path,
    guards: guards,
    options: RouteOptions(
      operationId: '${operationIdPrefix}Create',
      summary: 'Create a resumable upload resource.',
      success: const ResponseSpec.text(status: 201),
    ),
    handler: (context) async {
      final versionError = _validateVersion(context.req);
      if (versionError != null) return versionError;
      final length = ResumableUploadProtocol.parseNonNegativeInteger(
        context.req.header(ResumableUploadProtocol.lengthHeader),
      );
      final complete = ResumableUploadProtocol.parseBoolean(
        context.req.header(ResumableUploadProtocol.completeHeader),
      );
      if (length == null || complete != false) {
        return _problem(
          status: 400,
          type: 'invalid-upload-creation',
          detail: 'Careful creation requires Upload-Length and Upload-Complete: ?0.',
        );
      }
      if (limits.maxSize case final maxSize? when length > maxSize) {
        return _problem(
          status: 413,
          type: 'upload-too-large',
          detail: 'Upload length $length exceeds the maximum size $maxSize.',
          headers: _limitHeaders(limits),
        );
      }
      if (limits.minSize case final minSize? when length < minSize) {
        return _problem(
          status: 400,
          type: 'upload-too-small',
          detail: 'Upload length $length is below the minimum size $minSize.',
          headers: _limitHeaders(limits),
        );
      }

      final resource = await store.create(
        length: length,
        metadata: await metadataFor?.call(context) ?? const <String, String>{},
        maxAge: limits.maxAge,
      );
      final location = locationFor(context, resource);
      return RawResponse.text(
        status: 201,
        headers: _resourceHeaders(resource, limits: limits, location: location),
      );
    },
  );

  final resourcePath = '$path/<uploadId>';
  router.head<RawResponse>(
    resourcePath,
    guards: guards,
    options: RouteOptions(
      operationId: '${operationIdPrefix}Inspect',
      summary: 'Retrieve the confirmed offset for a resumable upload.',
      success: const ResponseSpec.text(status: 204),
    ),
    handler: (context) async {
      final versionError = _validateVersion(context.req);
      if (versionError != null) return versionError;
      final resource = await _readResource(context.req, store);
      if (resource == null) return _notFound();
      return RawResponse.text(status: 204, headers: _resourceHeaders(resource, limits: limits));
    },
  );

  router.patch<RawResponse>(
    resourcePath,
    guards: guards,
    options: RouteOptions(
      operationId: '${operationIdPrefix}Append',
      summary: 'Append bytes to a resumable upload resource.',
      body: store is NativeResumableUploadStore
          ? const RequestBody.binaryStream(
              contentType: ResumableUploadProtocol.partialUploadMediaType,
            )
          : const RequestBody.binary(contentType: ResumableUploadProtocol.partialUploadMediaType),
      success: const ResponseSpec.text(status: 204),
    ),
    handler: (context) async {
      final versionError = _validateVersion(context.req);
      if (versionError != null) return versionError;
      final contentType = context.req.header('content-type')?.split(';').first.trim().toLowerCase();
      if (contentType != ResumableUploadProtocol.partialUploadMediaType) {
        return _problem(
          status: 415,
          type: 'unsupported-upload-media-type',
          detail: 'Upload appends require ${ResumableUploadProtocol.partialUploadMediaType}.',
        );
      }
      final expectedOffset = ResumableUploadProtocol.parseNonNegativeInteger(
        context.req.header(ResumableUploadProtocol.offsetHeader),
      );
      final complete = ResumableUploadProtocol.parseBoolean(
        context.req.header(ResumableUploadProtocol.completeHeader),
      );
      if (expectedOffset == null || complete == null) {
        return _problem(
          status: 400,
          type: 'invalid-upload-append',
          detail: 'Append requires valid Upload-Offset and Upload-Complete headers.',
        );
      }
      final id = context.req.param('uploadId');
      if (id == null || id.isEmpty) return _notFound();
      final existing = await store.read(id);
      if (existing == null) return _notFound();
      final declaredLength = ResumableUploadProtocol.parseNonNegativeInteger(
        context.req.header(ResumableUploadProtocol.lengthHeader),
      );
      if (declaredLength != null && declaredLength != existing.length) {
        return _problem(
          status: 400,
          type: 'inconsistent-upload-length',
          detail: 'Upload-Length does not match the created upload resource.',
          headers: _resourceHeaders(existing, limits: limits),
        );
      }
      final nativeStream = context.req.nativeBodyOrNull;
      final bufferedBytes = context.req.maybeBody<Uint8List>();
      final contentLength = nativeStream is DartHttpServerNativeBodyStream
          ? nativeStream.contentLength
          : bufferedBytes?.length ?? 0;
      if (contentLength == null) {
        return _problem(
          status: 411,
          type: 'upload-append-length-required',
          detail: 'Streamed upload appends require Content-Length.',
          headers: _resourceHeaders(existing, limits: limits),
        );
      }
      if (contentLength > limits.maxAppendSize) {
        return _problem(
          status: 413,
          type: 'upload-append-too-large',
          detail: 'Append length $contentLength exceeds ${limits.maxAppendSize}.',
          headers: _resourceHeaders(existing, limits: limits),
        );
      }
      final minAppendSize = limits.minAppendSize;
      if (!complete && minAppendSize != null && contentLength < minAppendSize) {
        return _problem(
          status: 400,
          type: 'upload-append-too-small',
          detail: 'Non-final append length $contentLength is below $minAppendSize.',
          headers: _resourceHeaders(existing, limits: limits),
        );
      }
      final content = nativeStream is DartHttpServerNativeBodyStream
          ? ResumableUploadContent.native(nativeStream, length: contentLength)
          : ResumableUploadContent.buffered(
              Stream<List<int>>.value(bufferedBytes ?? Uint8List(0)),
              length: contentLength,
            );

      try {
        final resource = await store.append(
          id: id,
          expectedOffset: expectedOffset,
          content: content,
          complete: complete,
        );
        if (resource.complete && onCompleted != null) {
          final response = await onCompleted(context, resource);
          return _withHeaders(response, _resourceHeaders(resource, limits: limits));
        }
        return RawResponse.text(status: 204, headers: _resourceHeaders(resource, limits: limits));
      } on ResumableUploadOffsetMismatchException catch (error) {
        final current = await store.read(id) ?? existing;
        return _problem(
          status: 400,
          type: 'mismatching-upload-offset',
          detail: error.message,
          headers: _resourceHeaders(current, limits: limits),
        );
      } on ResumableUploadLengthException catch (error) {
        final current = await store.read(id) ?? existing;
        return _problem(
          status: 409,
          type: 'inconsistent-upload-length',
          detail: error.message,
          headers: _resourceHeaders(current, limits: limits),
        );
      } on ResumableUploadAlreadyCompleteException catch (error) {
        final current = await store.read(id) ?? existing;
        return _problem(
          status: 409,
          type: 'upload-already-complete',
          detail: error.message,
          headers: _resourceHeaders(current, limits: limits),
        );
      } on ResumableUploadNotFoundException {
        return _notFound();
      }
    },
  );

  router.delete<RawResponse>(
    resourcePath,
    guards: guards,
    options: RouteOptions(
      operationId: '${operationIdPrefix}Cancel',
      summary: 'Cancel and discard a resumable upload resource.',
      success: const ResponseSpec.text(status: 204),
    ),
    handler: (context) async {
      final versionError = _validateVersion(context.req);
      if (versionError != null) return versionError;
      final id = context.req.param('uploadId');
      if (id == null || id.isEmpty) return _notFound();
      await store.cancel(id);
      return RawResponse.text(status: 204);
    },
  );
}

Future<ResumableUploadResource?> _readResource(
  RequestInput request,
  ResumableUploadStore store,
) async {
  final id = request.param('uploadId');
  return id == null || id.isEmpty ? null : store.read(id);
}

RawResponse? _validateVersion(RequestInput request) {
  final version = ResumableUploadProtocol.parseNonNegativeInteger(
    request.header(ResumableUploadProtocol.draftInteropVersionHeader),
  );
  if (version == ResumableUploadProtocol.draftInteropVersion) return null;
  return _problem(
    status: 400,
    type: 'unsupported-upload-draft-version',
    detail:
        'Expected draft interoperability version '
        '${ResumableUploadProtocol.draftInteropVersion}.',
  );
}

List<HttpHeader> _resourceHeaders(
  ResumableUploadResource resource, {
  required ResumableUploadLimits limits,
  Uri? location,
}) => <HttpHeader>[
  HttpHeader('Upload-Draft-Interop-Version', '${ResumableUploadProtocol.draftInteropVersion}'),
  HttpHeader('Upload-Offset', '${resource.offset}'),
  HttpHeader('Upload-Length', '${resource.length}'),
  HttpHeader('Upload-Complete', ResumableUploadProtocol.encodeBoolean(resource.complete)),
  HttpHeader('Upload-Limit', limits.toHeaderValue()),
  const HttpHeader('Cache-Control', 'no-store'),
  if (location != null) HttpHeader('Location', location.toString()),
];

List<HttpHeader> _limitHeaders(ResumableUploadLimits limits) => <HttpHeader>[
  HttpHeader('Upload-Draft-Interop-Version', '${ResumableUploadProtocol.draftInteropVersion}'),
  HttpHeader('Upload-Limit', limits.toHeaderValue()),
];

RawResponse _notFound() => _problem(
  status: 404,
  type: 'upload-resource-not-found',
  detail: 'The upload resource does not exist or has expired.',
);

RawResponse _problem({
  required int status,
  required String type,
  required String detail,
  List<HttpHeader> headers = const <HttpHeader>[],
}) {
  final problemType = switch (type) {
    'mismatching-upload-offset' ||
    'inconsistent-upload-length' => 'https://iana.org/assignments/http-problem-types#$type',
    _ => 'urn:dart-http:resumable-upload:$type',
  };
  return RawResponse(
    status: status,
    contentType: 'application/problem+json',
    headers: headers,
    body: <String, Object?>{'type': problemType, 'status': status, 'detail': detail},
  );
}

RawResponse _withHeaders(RawResponse response, List<HttpHeader> headers) {
  return RawResponse(
    status: response.status,
    contentType: response.contentType,
    body: response.body,
    headers: <HttpHeader>[...response.headers, ...headers],
    isEncodedBody: response.isEncodedBody,
  );
}
