import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:dart_http_server_runtime/dart_http_server_runtime.dart';
import 'package:dart_http_server_runtime/src/runtime/native_request.dart';
import 'package:dart_http_server_runtime/src/runtime/request_decoder.dart';
import 'package:dart_http_server_runtime/src/native/http_native_bridge.dart' as bridge;
import 'package:ffi/ffi.dart';
import 'package:json_schema/json_schema.dart';
import 'package:test/test.dart';

void main() {
  test('decodes typed path, query, header, and body values with runtime codecs', () async {
    final codecs = DartHttpCodecRegistry.empty
        .withCodec<UserPath>(
          'UserPath',
          DartHttpCodec<UserPath>(
            encode: (value) => {'id': value.id},
            decode: (value) {
              final map = _readObject(value);
              return UserPath(id: map['id']! as String);
            },
          ),
        )
        .withCodec<UserQuery>(
          'UserQuery',
          DartHttpCodec<UserQuery>(
            encode: (value) => {'search': value.search},
            decode: (value) {
              final map = _readObject(value);
              return UserQuery(search: map['search'] as String?);
            },
          ),
        )
        .withCodec<RequestHeaders>(
          'RequestHeaders',
          DartHttpCodec<RequestHeaders>(
            encode: (value) => {'x-request-id': value.requestId},
            decode: (value) {
              final map = _readObject(value);
              return RequestHeaders(requestId: map['x-request-id']! as String);
            },
          ),
        )
        .withCodec<CreateUserInput>(
          'CreateUserInput',
          DartHttpCodec<CreateUserInput>(
            encode: (value) => {'name': value.name},
            decode: (value) {
              final map = _readObject(value);
              return CreateUserInput(name: map['name']! as String);
            },
          ),
        );

    final input = await decodeRequestInput(
      TransportRequest(
        routeId: 'route_0',
        pathParams: const {'id': '42'},
        query: const {'search': 'Ada'},
        headers: const {'x-request-id': 'req_1'},
        bodyBytes: Uint8List.fromList(utf8.encode('{"name":"Ada"}')),
        bodyKind: TransportRequestBodyKind.json,
      ),
      codecs: codecs,
      paramsSchemaId: 'UserPath',
      querySchemaId: 'UserQuery',
      headersSchemaId: 'RequestHeaders',
      body: RequestBody.json(schema: const JsonSchema.ref('CreateUserInput')),
    );

    expect(input.params<UserPath>().id, '42');
    expect(input.query<UserQuery>().search, 'Ada');
    expect(input.headers<RequestHeaders>().requestId, 'req_1');
    expect(input.body<CreateUserInput>().name, 'Ada');
  });

  test('preserves raw request values when no runtime codec is registered', () async {
    final input = await decodeRequestInput(
      TransportRequest(
        routeId: 'route_0',
        pathParams: const {'id': '42'},
        query: const {'search': 'Ada'},
        headers: const {'x-request-id': 'req_1'},
        bodyBytes: Uint8List.fromList(utf8.encode('{"name":"Ada"}')),
        bodyKind: TransportRequestBodyKind.json,
      ),
      codecs: DartHttpCodecRegistry.empty,
      paramsSchemaId: 'UserPath',
      querySchemaId: 'UserQuery',
      headersSchemaId: 'RequestHeaders',
      body: RequestBody.json(schema: const JsonSchema.ref('CreateUserInput')),
    );

    expect(input.params<Map<String, String>>(), {'id': '42'});
    expect(input.query<Map<String, String>>(), {'search': 'Ada'});
    expect(input.headers<Map<String, String>>(), {'x-request-id': 'req_1'});
    expect(input.body<Map<String, Object?>>(), {'name': 'Ada'});
  });

  test('decodes request bodies with route-local body decoder', () async {
    final input = await decodeRequestInput(
      TransportRequest(
        routeId: 'route_0',
        pathParams: const <String, String>{},
        query: const <String, String>{},
        headers: const <String, String>{},
        bodyBytes: Uint8List.fromList(utf8.encode('{"name":"Ada"}')),
        bodyKind: TransportRequestBodyKind.json,
      ),
      codecs: DartHttpCodecRegistry.empty,
      paramsSchemaId: null,
      querySchemaId: null,
      headersSchemaId: null,
      body: RequestBody.json(
        schema: const JsonSchema.ref('CreateUserInput'),
        decoder: (value) {
          final map = _readObject(value);
          return CreateUserInput(name: map['name']! as String);
        },
      ),
    );

    expect(input.body<CreateUserInput>().name, 'Ada');
  });

  test('decodes URL-encoded request bodies before invoking the route decoder', () async {
    final input = await decodeRequestInput(
      TransportRequest(
        routeId: 'route_0',
        pathParams: const <String, String>{},
        query: const <String, String>{},
        headers: const <String, String>{},
        bodyBytes: Uint8List.fromList(utf8.encode('code=authorization%2Bcode&state=state%20value')),
      ),
      codecs: DartHttpCodecRegistry.empty,
      paramsSchemaId: null,
      querySchemaId: null,
      headersSchemaId: null,
      body: RequestBody.urlEncoded(decoder: (value) => _readObject(value)),
    );

    expect(input.body<Map<String, Object?>>(), {
      'code': 'authorization+code',
      'state': 'state value',
    });
  });

  test('preserves binary request bodies without UTF-8 decoding', () async {
    final bytes = Uint8List.fromList(<int>[0, 255, 1, 128]);
    final input = await decodeRequestInput(
      TransportRequest(
        routeId: 'route_0',
        pathParams: const <String, String>{},
        query: const <String, String>{},
        headers: const <String, String>{},
        bodyBytes: bytes,
      ),
      codecs: DartHttpCodecRegistry.empty,
      paramsSchemaId: null,
      querySchemaId: null,
      headersSchemaId: null,
      body: const RequestBody.binary(contentType: 'application/partial-upload'),
    );

    expect(input.body<Uint8List>(), bytes);
  });

  test('decodes multipart request bodies with route-local decoder', () async {
    final nativeBytes = calloc<Uint8>(3);
    nativeBytes.asTypedList(3).setAll(0, [1, 2, 3]);
    final nativeBytesView = calloc<bridge.NativeBytes>()
      ..ref.ptr = nativeBytes
      ..ref.len = 3;
    final borrowed = createBorrowedNativeRequestBody(nativeBytesView.ref);
    calloc.free(nativeBytesView);

    try {
      final nativeRequest = NativeRequest(
        routeId: 'route_0',
        pathParams: const <String, String>{},
        query: const <String, String>{},
        headers: const <String, String>{},
        body: borrowed.body,
        multipartLoader: () async => NativeMultipartForm(
          fields: const [
            NativeMultipartField(name: 'workspace_id', value: 'workspace_1'),
            NativeMultipartField(name: 'persist', value: 'true'),
          ],
          files: [NativeMultipartFile(fieldName: 'file', body: borrowed.body)],
        ),
      );

      final input = await decodeRequestInput(
        TransportRequest(
          routeId: 'route_0',
          pathParams: const <String, String>{},
          query: const <String, String>{},
          headers: const <String, String>{},
          bodyKind: TransportRequestBodyKind.multipart,
        ),
        codecs: DartHttpCodecRegistry.empty,
        nativeRequest: nativeRequest,
        paramsSchemaId: null,
        querySchemaId: null,
        headersSchemaId: null,
        body: RequestBody.multipartFormData(
          schema: const JsonSchema.ref('WorkspaceTranscribeBody'),
          decoder: (form) {
            return MultipartUploadBody(
              workspaceId: form.fieldValue('workspace_id')!,
              persist: bool.parse(form.fieldValue('persist')!),
              file: form.file('file')!,
            );
          },
        ),
      );

      final body = input.body<MultipartUploadBody>();
      expect(body.workspaceId, 'workspace_1');
      expect(body.persist, isTrue);
      expect(body.file.length, 3);
      expect(await body.file.bytes, [1, 2, 3]);
      final nativeFile = body.file as NativeMultipartFile;
      final nativeLease = nativeFile.copyNativeLease();
      expect(nativeLease.bytesView, [1, 2, 3]);
      borrowed.release();
      expect(nativeLease.bytesView, [1, 2, 3]);
      nativeLease.close();
    } finally {
      borrowed.release();
      calloc.free(nativeBytes);
    }
  });

  test('decodes params and query with route-local decoders', () async {
    final codecs = DartHttpCodecRegistry.empty
        .withCodec<UserPath>(
          'UserPath',
          DartHttpCodec<UserPath>(
            encode: (value) => {'id': value.id},
            decode: (_) => const UserPath(id: 'codec-path'),
          ),
        )
        .withCodec<UserQuery>(
          'UserQuery',
          DartHttpCodec<UserQuery>(
            encode: (value) => {'search': value.search},
            decode: (_) => const UserQuery(search: 'codec-query'),
          ),
        );

    final input = await decodeRequestInput(
      TransportRequest(
        routeId: 'route_0',
        pathParams: const {'id': '42'},
        query: const {'search': 'Ada'},
        headers: const <String, String>{},
      ),
      codecs: codecs,
      paramsSchemaId: 'UserPath',
      querySchemaId: 'UserQuery',
      headersSchemaId: null,
      paramsDecoder: (values) => UserPath(id: values['id']!),
      queryDecoder: (values) => UserQuery(search: values['search']),
      body: null,
    );

    expect(input.params<UserPath>().id, '42');
    expect(input.query<UserQuery>().search, 'Ada');
  });

  test('does not use inline schema ids as body codec targets', () async {
    final codecs = DartHttpCodecRegistry.empty.withCodec<CreateUserInput>(
      'CreateUserInput',
      DartHttpCodec<CreateUserInput>(
        encode: (value) => {'name': value.name},
        decode: (value) {
          final map = _readObject(value);
          return CreateUserInput(name: map['name']! as String);
        },
      ),
    );

    final input = await decodeRequestInput(
      TransportRequest(
        routeId: 'route_0',
        pathParams: const <String, String>{},
        query: const <String, String>{},
        headers: const <String, String>{},
        bodyBytes: Uint8List.fromList(utf8.encode('{"name":"Ada"}')),
        bodyKind: TransportRequestBodyKind.json,
      ),
      codecs: codecs,
      paramsSchemaId: null,
      querySchemaId: null,
      headersSchemaId: null,
      body: RequestBody.json(
        schema: const JsonSchema.object(
          id: 'CreateUserInput',
          properties: <String, JsonSchema>{'name': JsonSchema.string()},
        ),
      ),
    );

    expect(input.body<Map<String, Object?>>(), {'name': 'Ada'});
  });
}

Map<String, Object?> _readObject(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return {for (final entry in value.entries) '${entry.key}': entry.value};
  }

  throw StateError('Expected a JSON object, got ${value.runtimeType}.');
}

final class UserPath {
  const UserPath({required this.id});

  final String id;
}

final class UserQuery {
  const UserQuery({this.search});

  final String? search;
}

final class RequestHeaders {
  const RequestHeaders({required this.requestId});

  final String requestId;
}

final class CreateUserInput {
  const CreateUserInput({required this.name});

  final String name;
}

final class MultipartUploadBody {
  const MultipartUploadBody({required this.workspaceId, required this.persist, required this.file});

  final String workspaceId;
  final bool persist;
  final MultipartFile file;
}
