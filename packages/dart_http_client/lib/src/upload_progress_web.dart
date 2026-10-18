import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:dart_http_core/dart_http_core.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

/// XHR upload events are measured after send(), unlike source stream reads.
Future<DartHttpClientStreamedResponse>? sendWithUploadProgress(
  DartHttpClientRequest request, {
  required bool withCredentials,
  required Set<void Function()> aborts,
  required bool closed,
}) {
  if (request.onUploadProgress == null ||
      request.responseMode != DartHttpClientResponseMode.buffered) {
    return null;
  }
  if (closed) return Future.error(http.ClientException('HTTP client is closed.', request.uri));
  return _send(request, withCredentials: withCredentials, aborts: aborts);
}

Future<DartHttpClientStreamedResponse> _send(
  DartHttpClientRequest request, {
  required bool withCredentials,
  required Set<void Function()> aborts,
}) async {
  if (request.redirectPolicy == DartHttpClientRedirectPolicy.none) {
    throw UnsupportedError('Browser upload progress cannot disable redirects.');
  }
  if (request.nativeBody != null) throw UnsupportedError('Browser cannot consume a native body.');
  final xhr = web.XMLHttpRequest();
  final result = Completer<DartHttpClientStreamedResponse>();
  StreamSubscription<List<int>>? sourceSubscription;
  final body = Completer<Uint8List>();
  var active = true;
  var aborted = false;
  void fail(Object error) {
    if (!body.isCompleted) body.completeError(error);
    if (!result.isCompleted) result.completeError(error);
  }

  // Attach an error handler immediately, including cancellation during preparation.
  final responseFuture = result.future;
  unawaited(responseFuture.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  void abort() {
    if (!active) return;
    aborted = true;
    unawaited(sourceSubscription?.cancel());
    xhr.abort();
    fail(http.RequestAbortedException(request.uri));
  }

  aborts.add(abort);
  request.abortTrigger?.then<void>((_) => abort(), onError: (Object _, StackTrace _) {});

  try {
    xhr.open(request.method.wireName, request.uri.toString());
    xhr.responseType = 'arraybuffer';
    xhr.withCredentials = withCredentials;
    for (final entry in request.headers.entries) {
      if (entry.key.toLowerCase() != 'content-length') xhr.setRequestHeader(entry.key, entry.value);
    }
    var reported = 0;
    xhr.upload.onprogress = ((web.ProgressEvent event) {
      if (!active || aborted) return;
      final bytes = event.loaded;
      if (bytes <= reported) return;
      reported = bytes;
      request.onUploadProgress!(
        DartHttpClientUploadProgress(
          bytes: bytes,
          totalBytes: event.lengthComputable ? event.total : null,
          measurement: DartHttpClientUploadMeasurement.transmitted,
        ),
      );
    }).toJS;
    xhr.onload = ((web.Event _) {
      if (!active || result.isCompleted) return;
      final headers = <String, String>{};
      for (final line in xhr.getAllResponseHeaders().split('\r\n')) {
        final separator = line.indexOf(':');
        if (separator > 0) {
          headers[line.substring(0, separator).toLowerCase()] = line
              .substring(separator + 1)
              .trim();
        }
      }
      final response = xhr.response;
      final bytes = response == null
          ? Uint8List(0)
          : (response as JSArrayBuffer).toDart.asUint8List();
      result.complete(
        DartHttpClientStreamedResponse(
          status: xhr.status,
          contentType: headers['content-type'] ?? '',
          headers: headers,
          bodyStream: Stream<List<int>>.value(bytes),
        ),
      );
    }).toJS;
    xhr.onerror = ((web.Event _) => fail(
      http.ClientException('Browser upload failed.', request.uri),
    )).toJS;
    xhr.onabort = ((web.Event _) => fail(http.RequestAbortedException(request.uri))).toJS;
    if (request.bodyStream case final stream?) {
      final builder = BytesBuilder(copy: false);
      sourceSubscription = stream.listen(
        builder.add,
        onError: (Object error, StackTrace stack) {
          if (!body.isCompleted) body.completeError(error, stack);
        },
        onDone: () {
          if (!body.isCompleted) body.complete(builder.takeBytes());
        },
        cancelOnError: true,
      );
    } else {
      body.complete(
        request.bodyLease?.takeDartBytes() ??
            Uint8List.fromList(request.bodyBytes ?? utf8.encode(request.body ?? '')),
      );
    }
    final bytes = await body.future;
    if (aborted) throw http.RequestAbortedException(request.uri);
    if (request.bodyStreamLength case final expected? when expected != bytes.length) {
      throw StateError('Upload source produced ${bytes.length} bytes, expected $expected.');
    }
    xhr.send(bytes.toJS);
    return await responseFuture;
  } finally {
    active = false;
    aborts.remove(abort);
    unawaited(sourceSubscription?.cancel());
    xhr.upload.onprogress = null;
    xhr.onload = null;
    xhr.onerror = null;
    xhr.onabort = null;
    xhr.abort();
  }
}
