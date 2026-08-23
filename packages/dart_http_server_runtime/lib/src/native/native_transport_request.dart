import 'dart:ffi';

import 'package:dart_http_server_runtime/src/native/http_native_bridge.dart' as core_ffi;
import 'package:ffi/ffi.dart';

import '../runtime/native_request.dart';
import '../runtime/transport_request.dart';
import 'generated_bindings.dart' as gen;

final class DecodedNativeTransportRequest {
  const DecodedNativeTransportRequest({
    required this.request,
    required this.nativeRequest,
    this.releaseNativeBody,
  });

  final TransportRequest request;
  final NativeRequest nativeRequest;
  final void Function()? releaseNativeBody;
}

DecodedNativeTransportRequest decodeNativeTransportRequest(
  Pointer<gen.NativeTransportRequest> requestPtr,
) {
  final request = requestPtr.ref;
  final routeId = _decodeUtf8(request.route_id);
  final pathParams = _decodePairs(request.path_params, request.path_param_count);
  final query = _decodePairs(request.query, request.query_count);
  final headers = _decodePairs(request.headers, request.header_count);
  final nativeBodyData = _nativeBodyData(request.body);
  final nativeBody = nativeBodyData?.body;

  return DecodedNativeTransportRequest(
    request: TransportRequest(
      routeId: routeId,
      pathParams: pathParams,
      query: query,
      headers: headers,
      nativeBody: nativeBody,
      requestKind: switch (request.request_kind) {
        1 => TransportRequestKind.webSocket,
        2 => TransportRequestKind.webTransport,
        _ => TransportRequestKind.http,
      },
      bodyKind: switch (request.body_kind) {
        1 => TransportRequestBodyKind.text,
        2 => TransportRequestBodyKind.json,
        3 => TransportRequestBodyKind.multipart,
        _ => TransportRequestBodyKind.none,
      },
    ),
    nativeRequest: NativeRequest(
      routeId: routeId,
      pathParams: pathParams,
      query: query,
      headers: headers,
      body: nativeBody,
      multipartLoader: nativeBody == null
          ? null
          : () => _decodeNativeMultipartForm(requestPtr, headers: headers, requestBody: nativeBody),
    ),
    releaseNativeBody: nativeBodyData?.release,
  );
}

Map<String, String> _decodePairs(Pointer<core_ffi.NativePair> pairs, int count) {
  return {for (final pair in core_ffi.copyNativePairs(pairs, count)) pair.key: pair.value};
}

String _decodeUtf8(core_ffi.NativeBytes value) => core_ffi.decodeNativeUtf8(value);

String? _decodeOptionalUtf8(core_ffi.NativeBytes value) {
  if (value.len == 0 || value.ptr == nullptr) {
    return null;
  }

  return _decodeUtf8(value);
}

({NativeRequestBody body, void Function() release})? _nativeBodyData(core_ffi.NativeBytes value) {
  if (value.len == 0 || value.ptr == nullptr) {
    return null;
  }

  return createBorrowedNativeRequestBody(value);
}

Future<NativeMultipartForm> _decodeNativeMultipartForm(
  Pointer<gen.NativeTransportRequest> requestPtr, {
  required Map<String, String> headers,
  required NativeRequestBody requestBody,
}) async {
  requestBody.ensureActive();

  final contentType = headers['content-type'];
  if (contentType == null || !_isMultipartFormData(contentType)) {
    throw StateError('This request is not multipart/form-data.');
  }

  final contentTypePtr = contentType.toNativeUtf8();
  try {
    final formPtr = gen.dart_http_server_runtime_parse_multipart(
      requestPtr,
      contentTypePtr.cast<Char>(),
    );
    if (formPtr == nullptr) {
      throw StateError(_takeLastError());
    }

    try {
      final form = formPtr.ref;
      final fields = <NativeMultipartField>[
        for (var index = 0; index < form.field_count; index += 1)
          NativeMultipartField(
            name: _decodeUtf8((form.fields + index).ref.name),
            value: _decodeUtf8((form.fields + index).ref.value),
          ),
      ];
      final files = <NativeMultipartFile>[
        for (var index = 0; index < form.file_count; index += 1)
          NativeMultipartFile(
            fieldName: _decodeUtf8((form.files + index).ref.field_name),
            filename: _decodeOptionalUtf8((form.files + index).ref.filename),
            contentType: _decodeOptionalUtf8((form.files + index).ref.content_type),
            body: borrowNativeRequestBodyView((form.files + index).ref.body, requestBody),
          ),
      ];
      return NativeMultipartForm(fields: fields, files: files);
    } finally {
      gen.dart_http_server_runtime_free_multipart_form(formPtr);
    }
  } finally {
    calloc.free(contentTypePtr);
  }
}

bool _isMultipartFormData(String contentType) {
  final mimeType = contentType.split(';').first.trim().toLowerCase();
  return mimeType == 'multipart/form-data';
}

String _takeLastError() {
  final errorPtr = gen.dart_http_server_runtime_take_last_error();
  if (errorPtr == nullptr) {
    return 'dart_http_server_runtime native call failed.';
  }

  try {
    final message = errorPtr.cast<Utf8>().toDartString();
    if (message.isEmpty) {
      return 'dart_http_server_runtime native call failed.';
    }
    return message;
  } finally {
    gen.dart_http_server_runtime_free_string(errorPtr);
  }
}
