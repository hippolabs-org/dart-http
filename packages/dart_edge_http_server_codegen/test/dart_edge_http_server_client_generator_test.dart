import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_edge_core/dart_edge_core.dart';
import 'package:dart_edge_http_server_codegen/dart_edge_http_server_codegen.dart';
import 'package:json_schema/json_schema.dart';
import 'package:test/test.dart';

void main() {
  group('DartEdgeClientGenerator', () {
    test('emits a client class from route metadata', () {
      final source = const DartEdgeClientGenerator().generate(
        DartEdgeClientLibrarySpec(
          className: 'UsersClient',
          additionalImports: const ['package:example/models.dart'],
          operations: [
            DartEdgeClientOperation(
              method: HttpMethod.get,
              path: '/users/<id>',
              options: RouteOptions(
                operationId: 'getUser',
                params: const JsonSchema.ref('UserPath'),
                query: const JsonSchema.ref('GetUserQuery'),
                success: ResponseSpec.json(schema: const JsonSchema.ref('UserDto')),
                errors: const [ErrorResponse(status: 404, code: 'not_found')],
              ),
              successType: 'UserDto',
              paramsType: 'UserPath',
              queryType: 'GetUserQuery',
            ),
          ],
        ),
      );

      expect(source, contains('final class UsersClient'));
      expect(source, contains('final class GetUserOperation'));
      expect(source, contains('GetUserOperation get getUser'));
      expect(source, contains('DartEdgeClientOperationInfo get info'));
      expect(source, contains("operationId: 'getUser'"));
      expect(source, contains('method: HttpMethod.get'));
      expect(source, contains('Future<DartEdgeClientResponseObject<UserDto>> call({'));
      expect(source, contains('Future<void>? abortTrigger'));
      expect(source, contains('Duration? timeout'));
      expect(
        source,
        contains('DartEdgeClientRequestHandle<DartEdgeClientResponseObject<UserDto>> start({'),
      );
      expect(source, contains('abortTrigger: abortTrigger'));
      expect(source, contains('timeout: timeout'));
      expect(source, contains("pathTemplate: '/users/<id>'"));
      expect(source, contains('invoke<UserDto, UserPath, GetUserQuery?, Never, Never>'));
      expect(source, contains("DartEdgeClientErrorSpec(status: 404, code: 'not_found')"));
      expect(source, contains("schemaId: 'UserPath'"));
      expect(source, contains("schemaId: 'GetUserQuery'"));
      expect(source, contains("schemaId: 'UserDto'"));
      expect(source, contains("import 'package:example/models.dart';"));
    });

    test('emits websocket connect methods', () {
      final source = const DartEdgeClientGenerator().generate(
        const DartEdgeClientLibrarySpec(
          className: 'RealtimeClient',
          operations: [],
          webSockets: [
            DartEdgeClientWebSocketOperation(
              path: '/rooms/<id>/socket',
              operationId: 'connectRoom',
              params: JsonSchema.ref('RoomPath'),
              paramsType: 'RoomPath',
              query: JsonSchema.ref('RoomQuery'),
              queryType: 'RoomQuery',
            ),
          ],
        ),
      );

      expect(source, contains('Future<DartEdgeClientWebSocket> connect({'));
      expect(source, contains('ConnectRoomOperation get connectRoom'));
      expect(source, contains('kind: DartEdgeClientOperationKind.webSocket'));
      expect(source, contains("pathTemplate: '/rooms/<id>/socket'"));
      expect(source, contains('RoomQuery? query'));
      expect(source, contains('connectWebSocket<RoomPath, RoomQuery?, Never>'));
      expect(source, contains("schemaId: 'RoomQuery'"));
    });

    test('emits webtransport connect methods', () {
      final source = const DartEdgeClientGenerator().generate(
        const DartEdgeClientLibrarySpec(
          className: 'RealtimeClient',
          operations: [],
          webTransports: [
            DartEdgeClientWebTransportOperation(
              path: '/rooms/<id>/transport',
              operationId: 'connectRoomTransport',
              paramsType: 'RoomPath',
            ),
          ],
        ),
      );

      expect(source, contains('Future<DartEdgeClientWebTransportSession> connect({'));
      expect(source, contains('ConnectRoomTransportOperation get connectRoomTransport'));
      expect(source, contains('kind: DartEdgeClientOperationKind.webTransport'));
      expect(source, contains("pathTemplate: '/rooms/<id>/transport'"));
      expect(source, contains('connectWebTransport<RoomPath, Never, Never>'));
    });

    test('emits Uint8List bindings for binary response contracts', () {
      final source = const DartEdgeClientGenerator().generate(
        const DartEdgeClientLibrarySpec(
          className: 'AudioClient',
          operations: [
            DartEdgeClientOperation(
              method: HttpMethod.get,
              path: '/tone.wav',
              options: RouteOptions(
                operationId: 'getTone',
                success: ResponseSpec.binary(contentType: 'audio/wav'),
              ),
              successType: 'Uint8List',
            ),
          ],
        ),
      );

      expect(source, contains("import 'dart:typed_data';"));
      expect(source, contains('Future<DartEdgeClientResponseObject<Uint8List>> call({'));
      expect(source, contains('Future<DartEdgeClientStreamedResponseObject> stream({'));
      expect(source, contains('DartEdgeClientResponseSpec<Uint8List>'));
      expect(source, isNot(contains('Uint8List.decode')));
      expect(source, contains('Duration? timeout'));
      expect(source, contains('invokeStream<Never, Never, Never, Never>'));
      expect(source, contains('abortTrigger: abortTrigger'));
    });

    test('emits streamed bindings for SSE response contracts', () {
      final source = const DartEdgeClientGenerator().generate(
        const DartEdgeClientLibrarySpec(
          className: 'EventsClient',
          operations: [
            DartEdgeClientOperation(
              method: HttpMethod.get,
              path: '/events',
              options: RouteOptions(operationId: 'subscribeEvents', success: ResponseSpec.sse()),
              successType: 'Object?',
            ),
          ],
        ),
      );

      expect(source, contains('Future<DartEdgeClientStreamedResponseObject> call({'));
      expect(source, contains('invokeStream<Never, Never, Never, Never>'));
      expect(source, contains("contentType: 'text/event-stream; charset=utf-8'"));
      expect(source, contains('Duration? timeout'));
      expect(source, contains('abortTrigger: abortTrigger'));
    });

    test('infers Uint8List for generated clients from binary response specs', () {
      final router = Router<void>();
      router.get(
        '/tone.wav',
        options: const RouteOptions(
          operationId: 'getTone',
          success: ResponseSpec.binary(contentType: 'audio/wav'),
        ),
        handler: (_) => Uint8List(0),
      );

      final spec = DartEdgeClientLibrarySpec.fromRouter(className: 'AudioClient', router: router);

      expect(spec.operations.single.successType, 'Uint8List');
    });

    test('emits split client library and bindings parts', () {
      final spec = DartEdgeClientLibrarySpec(
        className: 'UsersClient',
        schemas: const [
          JsonSchema.object(
            id: 'UserDto',
            properties: {'id': JsonSchema.string(), 'name': JsonSchema.string()},
            required: ['id', 'name'],
            additionalProperties: false,
          ),
        ],
        operations: [
          DartEdgeClientOperation(
            method: HttpMethod.post,
            path: '/users',
            options: const RouteOptions(
              operationId: 'createUser',
              body: RequestBody.json(schema: JsonSchema.ref('CreateUserBody')),
              success: ResponseSpec.json(schema: JsonSchema.ref('UserDto')),
            ),
            successType: 'UserDto',
            bodyType: 'CreateUserBody',
          ),
        ],
      );

      final generator = const DartEdgeClientGenerator();
      final library = generator.generateLibrary(spec);
      final bindings = generator.generateBindingsPart(spec);
      final models = generator.generateModelsPart(spec);

      expect(library, contains("import 'package:dart_edge_core/dart_edge_core.dart';"));
      expect(library, contains("import 'package:json_schema/json_schema.dart';"));
      expect(library, contains("part 'client.models.g.dart';"));
      expect(library, contains("part 'client.bindings.g.dart';"));
      expect(bindings, contains("part of 'client.g.dart';"));
      expect(bindings, contains('final class UsersClient'));
      expect(bindings, contains('Future<DartEdgeClientResponseObject<UserDto>> call({'));
      expect(models, contains("part of 'client.g.dart';"));
      expect(models, contains('final class UserDto implements JsonEncodable'));
      expect(models, contains('factory UserDto.decode(Object? value)'));
      expect(models, contains('factory UserDto.fromJson(Map<String, Object?> json)'));
    });

    test('encodes required nullable date-time fields as nullable', () {
      final spec = DartEdgeClientLibrarySpec(
        className: 'UsersClient',
        schemas: const [
          JsonSchema.object(
            id: 'UserDto',
            properties: {
              'id': JsonSchema.string(),
              'ban_expires': JsonSchema.string(nullable: true, format: 'date-time'),
            },
            required: ['id', 'ban_expires'],
            additionalProperties: false,
          ),
        ],
        operations: [
          DartEdgeClientOperation(
            method: HttpMethod.get,
            path: '/users/<id>',
            options: const RouteOptions(
              operationId: 'getUser',
              success: ResponseSpec.json(schema: JsonSchema.ref('UserDto')),
            ),
            successType: 'UserDto',
          ),
        ],
      );

      final models = const DartEdgeClientGenerator().generateModelsPart(spec);

      expect(models, contains('final DateTime? banExpires;'));
      expect(models, contains("banExpires: json['ban_expires'] == null"));
      expect(models, contains("? null\n          : DateTime.parse(json['ban_expires'] as String)"));
      expect(models, contains("'ban_expires': banExpires?.toIso8601String()"));
    });

    test('emits named string scalar client model fields', () {
      final spec = DartEdgeClientLibrarySpec(
        className: 'WorkspaceClient',
        schemas: const [
          JsonSchema.object(
            id: 'ListWorkspaceFilesBody',
            properties: {
              'workspace_id': JsonSchema.string(
                format: 'uuid',
                dartType: DartSchemaType.value('WorkspaceWorkspaceId'),
              ),
              'folder_id': JsonSchema.string(
                nullable: true,
                format: 'uuid',
                dartType: DartSchemaType.value('WorkspaceWorkspaceFolderId'),
              ),
            },
            required: ['workspace_id'],
            additionalProperties: false,
          ),
        ],
        operations: [
          DartEdgeClientOperation(
            method: HttpMethod.post,
            path: '/workspace/files',
            options: const RouteOptions(
              operationId: 'listWorkspaceFiles',
              body: RequestBody.json(schema: JsonSchema.ref('ListWorkspaceFilesBody')),
              success: ResponseSpec.json(),
            ),
            successType: 'Object?',
            bodyType: 'ListWorkspaceFilesBody',
          ),
        ],
      );

      final models = const DartEdgeClientGenerator().generateModelsPart(spec);

      expect(models, contains('final WorkspaceWorkspaceId workspaceId;'));
      expect(models, contains('final WorkspaceWorkspaceFolderId? folderId;'));
      expect(
        models,
        contains("workspaceId: WorkspaceWorkspaceId(json['workspace_id']! as String)"),
      );
      expect(models, contains("WorkspaceWorkspaceFolderId(json['folder_id'] as String)"));
      expect(models, contains("'workspace_id': workspaceId.value"));
      expect(models, contains("'folder_id': folderId?.value"));
    });

    test('emits model string scalar client model fields', () {
      final spec = DartEdgeClientLibrarySpec(
        className: 'WorkspaceClient',
        schemas: const [
          JsonSchema.object(
            id: 'RenameWorkspaceBody',
            properties: {
              'workspace_name': JsonSchema.string(dartType: DartSchemaType.model('WorkspaceName')),
            },
            required: ['workspace_name'],
            additionalProperties: false,
          ),
        ],
        operations: [
          DartEdgeClientOperation(
            method: HttpMethod.post,
            path: '/workspace/rename',
            options: const RouteOptions(
              operationId: 'renameWorkspace',
              body: RequestBody.json(schema: JsonSchema.ref('RenameWorkspaceBody')),
              success: ResponseSpec.json(),
            ),
            successType: 'Object?',
            bodyType: 'RenameWorkspaceBody',
          ),
        ],
      );

      final models = const DartEdgeClientGenerator().generateModelsPart(spec);

      expect(models, contains('final WorkspaceName workspaceName;'));
      expect(models, contains("workspaceName: WorkspaceName.decode(json['workspace_name']!)"));
      expect(models, contains("'workspace_name': workspaceName.toJson()"));
    });

    test('emits multipart client body models and encoders', () {
      final spec = DartEdgeClientLibrarySpec(
        className: 'UploadsClient',
        schemas: const [
          JsonSchema.object(
            id: 'UploadBody',
            properties: {
              'workspace_id': JsonSchema.string(),
              'persist': JsonSchema.boolean(),
              'file': JsonSchema.string(format: 'binary'),
              'attachments': JsonSchema.array(items: JsonSchema.string(format: 'binary')),
            },
            required: ['workspace_id', 'persist', 'file', 'attachments'],
            additionalProperties: false,
          ),
        ],
        operations: [
          DartEdgeClientOperation(
            method: HttpMethod.post,
            path: '/uploads',
            options: const RouteOptions(
              operationId: 'upload',
              body: RequestBody.multipartFormData(schema: JsonSchema.ref('UploadBody')),
              success: ResponseSpec.json(),
            ),
            successType: 'Object?',
            bodyType: 'UploadBody',
          ),
        ],
      );

      final generator = const DartEdgeClientGenerator();
      final bindings = generator.generateBindingsPart(spec);
      final models = generator.generateModelsPart(spec);

      expect(bindings, contains('encoder: (value) => value.toMultipartFormData()'));
      expect(
        bindings,
        contains(
          'void Function(DartEdgeMultipartUploadProgress progress)? '
          'onUploadProgress',
        ),
      );
      expect(bindings, contains('onMultipartUploadProgress: onUploadProgress'));
      expect(models, contains('final class UploadBody'));
      expect(models, isNot(contains('implements JsonEncodable')));
      expect(models, contains('final MultipartUploadFile file;'));
      expect(models, contains('final List<MultipartUploadFile> attachments;'));
      expect(models, contains('MultipartFormData toMultipartFormData()'));
      expect(models, contains('MultipartFormField(name: "workspace_id"'));
      expect(models, contains('file.asFile("file")'));
      expect(models, contains('for (final file in attachments)'));
    });

    test('emits inline multipart client body schemas as upload DTOs', () {
      const bodySchema = JsonSchema.object(
        id: 'CreateWorkspaceRecordingSegmentBody',
        properties: {
          'workspace_id': JsonSchema.string(),
          'recording_id': JsonSchema.string(),
          'segment_index': JsonSchema.integer(),
          'file': JsonSchema.string(format: 'binary'),
        },
        required: ['workspace_id', 'recording_id', 'segment_index', 'file'],
        additionalProperties: false,
      );
      final spec = DartEdgeClientLibrarySpec(
        className: 'WorkspaceClient',
        schemas: const [bodySchema],
        operations: [
          DartEdgeClientOperation(
            method: HttpMethod.post,
            path: '/workspace/recording-segments',
            options: const RouteOptions(
              operationId: 'createWorkspaceRecordingSegment',
              body: RequestBody.multipartFormData(schema: bodySchema),
              success: ResponseSpec.json(),
            ),
            successType: 'Object?',
            bodyType: 'CreateWorkspaceRecordingSegmentBody',
          ),
        ],
      );

      final generator = const DartEdgeClientGenerator();
      final bindings = generator.generateBindingsPart(spec);
      final models = generator.generateModelsPart(spec);

      expect(bindings, contains('encoder: (value) => value.toMultipartFormData()'));
      expect(models, contains('final class CreateWorkspaceRecordingSegmentBody'));
      expect(models, isNot(contains('implements JsonEncodable')));
      expect(models, contains('final MultipartUploadFile file;'));
      expect(models, contains('MultipartFormData toMultipartFormData()'));
      expect(models, contains('file.asFile("file")'));
      expect(models, isNot(contains('final String file;')));
    });

    test('emits named string scalar multipart fields', () {
      final spec = DartEdgeClientLibrarySpec(
        className: 'UploadsClient',
        schemas: const [
          JsonSchema.object(
            id: 'UploadBody',
            properties: {
              'workspace_id': JsonSchema.string(
                format: 'uuid',
                dartType: DartSchemaType.value('WorkspaceWorkspaceId'),
              ),
              'folder_id': JsonSchema.string(
                nullable: true,
                format: 'uuid',
                dartType: DartSchemaType.value('WorkspaceWorkspaceFolderId'),
              ),
              'file': JsonSchema.string(format: 'binary'),
            },
            required: ['workspace_id', 'file'],
            additionalProperties: false,
          ),
        ],
        operations: [
          DartEdgeClientOperation(
            method: HttpMethod.post,
            path: '/uploads',
            options: const RouteOptions(
              operationId: 'upload',
              body: RequestBody.multipartFormData(schema: JsonSchema.ref('UploadBody')),
              success: ResponseSpec.json(),
            ),
            successType: 'Object?',
            bodyType: 'UploadBody',
          ),
        ],
      );

      final models = const DartEdgeClientGenerator().generateModelsPart(spec);

      expect(models, contains('final WorkspaceWorkspaceId workspaceId;'));
      expect(models, contains('final WorkspaceWorkspaceFolderId? folderId;'));
      expect(models, contains('value: workspaceId.value.toString()'));
      expect(models, contains('value: folderId!.value.toString()'));
    });

    test('uses configured formatter page width for model parts', () {
      final models = const DartEdgeClientGenerator().generateModelsPart(
        const DartEdgeClientLibrarySpec(
          className: 'UsersClient',
          operations: [
            DartEdgeClientOperation(
              method: HttpMethod.get,
              path: '/users/<id>',
              options: RouteOptions(
                operationId: 'getUser',
                success: ResponseSpec.json(schema: JsonSchema.ref('UserDto')),
              ),
              successType: 'UserDto',
            ),
          ],
          schemas: [
            JsonSchema.object(
              id: 'UserDto',
              properties: {
                'id': JsonSchema.string(),
                'display_username': JsonSchema.string(nullable: true),
              },
              required: ['id'],
              additionalProperties: false,
            ),
          ],
        ),
        formatterOptions: const DartEdgeClientFormatterOptions(pageWidth: 100),
      );

      expect(
        models,
        contains(
          "displayUsername: json['display_username'] == null ? null : "
          "json['display_username'] as String,",
        ),
      );
    });

    test('emits split client files into an existing or new directory', () async {
      final output = await Directory.systemTemp.createTemp('dart_edge_client_');
      addTearDown(() => output.delete(recursive: true));

      await const DartEdgeClientFileEmitter().emit(
        DartEdgeClientLibrarySpec(
          className: 'UsersClient',
          schemas: const [
            JsonSchema.object(
              id: 'UserDto',
              properties: {'id': JsonSchema.string()},
              required: ['id'],
              additionalProperties: false,
            ),
          ],
          operations: [
            DartEdgeClientOperation(
              method: HttpMethod.get,
              path: '/users/<id>',
              options: const RouteOptions(
                operationId: 'getUser',
                success: ResponseSpec.json(schema: JsonSchema.ref('UserDto')),
              ),
              successType: 'UserDto',
            ),
          ],
        ),
        output: Directory('${output.path}/generated'),
      );

      expect(File('${output.path}/generated/client.g.dart').existsSync(), isTrue);
      expect(File('${output.path}/generated/client.bindings.g.dart').existsSync(), isTrue);
      expect(
        await File('${output.path}/generated/client.models.g.dart').readAsString(),
        contains('final class UserDto implements JsonEncodable'),
      );
    });

    test('file emitter uses configured formatter page width', () async {
      final output = await Directory.systemTemp.createTemp('dart_edge_client_');
      addTearDown(() => output.delete(recursive: true));

      await const DartEdgeClientFileEmitter(
        formatterOptions: DartEdgeClientFormatterOptions(pageWidth: 100),
      ).emit(
        const DartEdgeClientLibrarySpec(
          className: 'UsersClient',
          operations: [
            DartEdgeClientOperation(
              method: HttpMethod.get,
              path: '/users/<id>',
              options: RouteOptions(
                operationId: 'getUser',
                success: ResponseSpec.json(schema: JsonSchema.ref('UserDto')),
              ),
              successType: 'UserDto',
            ),
          ],
          schemas: [
            JsonSchema.object(
              id: 'UserDto',
              properties: {
                'id': JsonSchema.string(),
                'display_username': JsonSchema.string(nullable: true),
              },
              required: ['id'],
              additionalProperties: false,
            ),
          ],
        ),
        output: Directory('${output.path}/generated'),
      );

      expect(
        await File('${output.path}/generated/client.models.g.dart').readAsString(),
        contains(
          "displayUsername: json['display_username'] == null ? null : "
          "json['display_username'] as String,",
        ),
      );
    });

    test('discovers operations from a router registry', () {
      final router = Router<TestServices>();
      router.get(
        '/hello',
        options: const RouteOptions(operationId: 'getHello', success: ResponseSpec.text()),
        handler: (_) => 'hello',
      );
      router.post(
        '/users',
        options: const RouteOptions(
          operationId: 'createUser',
          body: RequestBody.json(schema: JsonSchema.ref('CreateUserBody')),
          success: ResponseSpec.json(schema: JsonSchema.ref('UserDto')),
        ),
        handler: (_) => const UserDto(id: '42', name: 'Ada'),
      );
      router.websocket(
        '/events/<id>',
        options: const WebSocketOptions(
          operationId: 'connectEvents',
          params: JsonSchema.ref('RoomPath'),
          query: JsonSchema.ref('UserQuery'),
        ),
        onConnect: (_) async {},
      );
      router.webtransport(
        '/datagrams',
        options: const WebTransportOptions(operationId: 'connectDatagrams'),
        onConnect: (_) async {},
      );
      final auth = router.router('/auth');
      auth.post(
        '/delete-user',
        options: const RouteOptions(operationId: 'deleteUser', success: ResponseSpec.json()),
        handler: (_) => const <String, Object?>{},
      );
      auth.websocket(
        '/session/socket',
        options: const WebSocketOptions(operationId: 'connectSession'),
        onConnect: (_) async {},
      );
      router.post(
        '/auth/update-user',
        options: const RouteOptions(operationId: 'updateUser', success: ResponseSpec.json()),
        handler: (_) => const <String, Object?>{},
      );

      final spec = DartEdgeClientLibrarySpec.fromRouter(
        className: 'DiscoveredClient',
        router: router,
      );
      final source = const DartEdgeClientGenerator().generate(spec);

      expect(source, contains('final class GetHelloOperation'));
      expect(source, contains('final class CreateUserOperation'));
      expect(source, contains('final class ConnectEventsOperation'));
      expect(source, contains('Future<DartEdgeClientWebSocket> connect({'));
      expect(source, contains('required RoomPath params'));
      expect(source, contains('UserQuery? query'));
      expect(source, contains("pathTemplate: '/events/<id>'"));
      expect(source, contains("schemaId: 'RoomPath'"));
      expect(source, contains("schemaId: 'UserQuery'"));
      expect(source, contains('final class ConnectDatagramsOperation'));
      expect(source, contains('authDeleteUser'));
      expect(source, contains("pathTemplate: '/auth/delete-user'"));
      expect(source, isNot(contains('Future<DartEdgeClientResponseObject<Object?>> deleteUser')));
      expect(source, contains('authUpdateUser'));
      expect(source, isNot(contains('Future<DartEdgeClientResponseObject<Object?>> updateUser')));
      expect(source, contains('final class AuthConnectSessionOperation'));
      expect(source, contains("pathTemplate: '/auth/session/socket'"));
    });

    test('generates client models from inline router schemas', () {
      const ownerSchema = JsonSchema.object(
        id: 'UserDto',
        properties: {'id': JsonSchema.string()},
        required: ['id'],
        additionalProperties: false,
      );
      const paramsSchema = JsonSchema.object(
        id: 'PhoneCallGetParams',
        properties: {'id': JsonSchema.string()},
        required: ['id'],
        additionalProperties: false,
      );
      const bodySchema = JsonSchema.object(
        id: 'UpdatePhoneCallBody',
        properties: {'subject': JsonSchema.string()},
        required: ['subject'],
        additionalProperties: false,
      );
      const responseSchema = JsonSchema.object(
        id: 'PhoneCallDto',
        properties: {'id': JsonSchema.string(), 'owner': JsonSchema.ref('UserDto')},
        required: ['id', 'owner'],
        additionalProperties: false,
      );
      final router = Router<TestServices>();
      router.put(
        '/phone-calls/<id>',
        options: const RouteOptions(
          operationId: 'updatePhoneCall',
          params: paramsSchema,
          body: RequestBody.json(schema: bodySchema),
          success: ResponseSpec.json(schema: responseSchema),
        ),
        handler: (_) => const <String, Object?>{},
      );

      final spec = DartEdgeClientLibrarySpec.fromRouter(
        className: 'PhoneCallsClient',
        router: router,
        schemas: const [ownerSchema],
      );
      final source = const DartEdgeClientGenerator().generate(spec);

      expect(source, contains('Future<DartEdgeClientResponseObject<PhoneCallDto>> call({'));
      expect(source, contains('required PhoneCallGetParams params'));
      expect(source, contains('required UpdatePhoneCallBody body'));
      expect(source, contains('final class PhoneCallGetParams implements JsonEncodable'));
      expect(source, contains('final class UpdatePhoneCallBody implements JsonEncodable'));
      expect(source, contains('final class PhoneCallDto implements JsonEncodable'));
      expect(source, contains('final class UserDto implements JsonEncodable'));
      expect(source, contains('final UserDto owner;'));
      expect(source, contains('owner: UserDto.decode(json[\'owner\']!),'));
      expect(source, contains("'owner': owner.toJson()"));
      expect(source, contains('decoder: PhoneCallDto.decode'));
      expect(source, contains('encoder: (value) => value.toJson()'));
      expect(source, isNot(contains("schemaId: 'PhoneCallDto'")));
      expect(source, isNot(contains("schemaId: 'PhoneCallGetParams'")));
      expect(source, isNot(contains("schemaId: 'UpdatePhoneCallBody'")));
    });

    test('uses schemaTypes as overrides for inline router schemas', () {
      const paramsSchema = JsonSchema.object(
        id: 'PhoneCallGetParams',
        properties: {'id': JsonSchema.string()},
        required: ['id'],
        additionalProperties: false,
      );
      final router = Router<TestServices>();
      router.get(
        '/phone-calls/<id>',
        options: const RouteOptions(
          operationId: 'getPhoneCall',
          params: paramsSchema,
          success: ResponseSpec.text(),
        ),
        handler: (_) => 'ok',
      );

      final spec = DartEdgeClientLibrarySpec.fromRouter(
        className: 'PhoneCallsClient',
        router: router,
        schemaTypes: const {'PhoneCallGetParams': 'Map<String, Object?>'},
      );
      final source = const DartEdgeClientGenerator().generate(spec);

      expect(source, contains('Future<DartEdgeClientResponseObject<String>> call({'));
      expect(source, contains('required Map<String, Object?> params'));
      expect(source, isNot(contains('final class PhoneCallGetParams implements')));
      expect(source, isNot(contains('encoder: (value) => value.toJson()')));
    });

    test('skips model generation for external schema ids', () {
      const ownerSchema = JsonSchema.object(
        id: 'UserDto',
        properties: {'id': JsonSchema.string()},
        required: ['id'],
        additionalProperties: false,
      );
      const responseSchema = JsonSchema.object(
        id: 'PhoneCallDto',
        properties: {'id': JsonSchema.string(), 'owner': JsonSchema.ref('UserDto')},
        required: ['id', 'owner'],
        additionalProperties: false,
      );
      final router = Router<TestServices>();
      router.get(
        '/phone-calls/<id>',
        options: const RouteOptions(
          operationId: 'getPhoneCall',
          success: ResponseSpec.json(schema: responseSchema),
        ),
        handler: (_) => const <String, Object?>{},
      );
      router.get(
        '/users/<id>',
        options: const RouteOptions(
          operationId: 'getUser',
          success: ResponseSpec.json(schema: JsonSchema.ref('UserDto')),
        ),
        handler: (_) => const <String, Object?>{},
      );

      final spec = DartEdgeClientLibrarySpec.fromRouter(
        className: 'PhoneCallsClient',
        router: router,
        schemas: const [ownerSchema],
        externalSchemaIds: const {'UserDto'},
      );
      final source = const DartEdgeClientGenerator().generate(spec);

      expect(source, contains('final class PhoneCallDto implements JsonEncodable'));
      expect(source, isNot(contains('final class UserDto implements')));
      expect(source, contains('final UserDto owner;'));
      expect(source, contains('owner: UserDto.decode(json[\'owner\']!),'));
      expect(source, contains('Future<DartEdgeClientResponseObject<UserDto>>'));
      expect(source, contains('decoder: UserDto.decode'));
      expect(source, contains("schemaId: 'UserDto'"));
    });

    test('throws a clear error for unresolved operation schema types', () {
      final router = Router<TestServices>();
      router.get(
        '/phone-calls/<id>',
        options: const RouteOptions(
          operationId: 'getPhoneCall',
          params: JsonSchema.ref('https://schemas.example.test/Params'),
          success: ResponseSpec.text(),
        ),
        handler: (_) => 'ok',
      );

      expect(
        () => DartEdgeClientLibrarySpec.fromRouter(className: 'PhoneCallsClient', router: router),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('params schema'),
              contains('getPhoneCall'),
              contains('/phone-calls/<id>'),
              contains('https://schemas.example.test/Params'),
            ),
          ),
        ),
      );
    });

    test('filters router discovery by exposure, path, and operation id', () {
      final router = Router<TestServices>();
      router.get(
        '/public',
        options: const RouteOptions(operationId: 'getPublic', success: ResponseSpec.text()),
        handler: (_) => 'public',
      );
      router.get(
        '/openapi-only',
        options: const RouteOptions(
          operationId: 'getOpenApiOnly',
          exposure: RouteExposure.openApiOnly,
          success: ResponseSpec.text(),
        ),
        handler: (_) => 'hidden',
      );
      router
          .router('/internal', exposure: RouteExposure.none)
          .get('/health', handler: (_) => const {'ok': true});
      router.get(
        '/ignored/:id',
        options: const RouteOptions(operationId: 'getIgnoredPath', success: ResponseSpec.text()),
        handler: (_) => 'ignored',
      );
      router.get(
        '/ignored/:id/details',
        options: const RouteOptions(
          operationId: 'getIgnoredPathDetails',
          success: ResponseSpec.text(),
        ),
        handler: (_) => 'ignored',
      );
      router.get(
        '/ignored-other',
        options: const RouteOptions(operationId: 'getIgnoredOther', success: ResponseSpec.text()),
        handler: (_) => 'included',
      );
      router.get(
        '/same',
        options: const RouteOptions(operationId: 'getSame', success: ResponseSpec.text()),
        handler: (_) => 'same',
      );
      router.post(
        '/same',
        options: const RouteOptions(operationId: 'mutateSame', success: ResponseSpec.text()),
        handler: (_) => 'same',
      );
      router.post(
        '/same/details',
        options: const RouteOptions(operationId: 'mutateSameDetails', success: ResponseSpec.text()),
        handler: (_) => 'same',
      );
      router.websocket(
        '/events',
        options: const WebSocketOptions(
          operationId: 'connectEvents',
          exposure: RouteExposure.openApiOnly,
        ),
        onConnect: (_) async {},
      );

      final spec = DartEdgeClientLibrarySpec.fromRouter(
        className: 'FilteredClient',
        router: router,
        options: const DartEdgeClientGenerationOptions(
          ignorePaths: {'/ignored/:id'},
          ignoreOperations: {'mutateSame'},
        ),
      );
      final source = const DartEdgeClientGenerator().generate(spec);

      expect(source, contains('final class GetPublicOperation'));
      expect(source, contains('final class GetSameOperation'));
      expect(source, contains('final class GetIgnoredOtherOperation'));
      expect(source, isNot(contains('getOpenApiOnly')));
      expect(source, isNot(contains('getInternalHealth')));
      expect(source, isNot(contains('getIgnoredPath')));
      expect(source, isNot(contains('getIgnoredPathDetails')));
      expect(source, isNot(contains('mutateSame')));
      expect(source, isNot(contains('mutateSameDetails')));
      expect(source, isNot(contains('connectEvents')));
    });

    test('does not emit schema ids for inline serializer targets', () {
      final source = const DartEdgeClientGenerator().generate(
        DartEdgeClientLibrarySpec(
          schemas: const [
            JsonSchema.object(id: 'CreateUserBody'),
            JsonSchema.object(id: 'UserDto'),
          ],
          className: 'UsersClient',
          operations: [
            DartEdgeClientOperation(
              method: HttpMethod.post,
              path: '/users',
              options: RouteOptions(
                operationId: 'createUser',
                body: RequestBody.json(schema: const JsonSchema.object(id: 'CreateUserBody')),
                success: ResponseSpec.json(schema: const JsonSchema.object(id: 'UserDto')),
              ),
              successType: 'UserDto',
              bodyType: 'CreateUserBody',
            ),
          ],
        ),
      );

      expect(source, isNot(contains("schemaId: 'CreateUserBody'")));
      expect(source, isNot(contains("schemaId: 'UserDto'")));
      expect(source, contains('decoder: UserDto.decode'));
      expect(source, contains('encoder: (value) => value.toJson()'));
    });
  });

  group('DartEdgeHttpClientBase', () {
    test('builds requests and decodes responses via generated serializers', () async {
      final abortTrigger = Completer<void>().future;
      final transport = _FakeTransport(
        onSend: (request) async {
          expect(request.method, HttpMethod.post);
          expect(
            request.uri,
            Uri.parse(
              'https://api.example.test/v1/users/42'
              '?includeDeleted=true'
              '&tags=alpha'
              '&tags=beta',
            ),
          );
          expect(request.headers, {
            'x-api-key': 'secret',
            'x-request-id': 'req_1',
            'content-type': 'application/json; charset=utf-8',
          });
          expect(jsonDecode(request.body!), {'name': 'Ada'});
          expect(request.abortTrigger, same(abortTrigger));

          return DartEdgeClientResponse(
            status: 201,
            contentType: 'application/json; charset=utf-8',
            headers: const {'x-response-id': 'res_1'},
            body: jsonEncode({'id': '42', 'name': 'Ada'}),
          );
        },
      );
      final client = _TestClient(
        baseUri: Uri.parse('https://api.example.test/v1'),
        transport: transport,
        defaultHeaders: const {'x-api-key': 'secret'},
      );

      final response = await client
          .invoke<UserDto, UserPath, UserQuery, RequestHeaders, CreateUserBody>(
            DartEdgeClientInvocation<UserDto, UserPath, UserQuery, RequestHeaders, CreateUserBody>(
              method: HttpMethod.post,
              pathTemplate: '/users/<id>',
              success: DartEdgeClientResponseSpec<UserDto>(
                status: 201,
                contentType: 'application/json; charset=utf-8',
                schemaId: 'UserDto',
                decoder: UserDto.decode,
              ),
              params: DartEdgeClientRequestValue<UserPath>(
                schemaId: 'UserPath',
                value: UserPath(id: '42'),
                encoder: UserPath.toJson,
              ),
              query: DartEdgeClientRequestValue<UserQuery>(
                schemaId: 'UserQuery',
                value: UserQuery(includeDeleted: true, tags: ['alpha', 'beta']),
                encoder: UserQuery.toJson,
              ),
              headers: DartEdgeClientRequestValue<RequestHeaders>(
                schemaId: 'RequestHeaders',
                value: RequestHeaders(requestId: 'req_1'),
                encoder: RequestHeaders.toJson,
              ),
              body: DartEdgeClientRequestBody<CreateUserBody>(
                contentType: 'application/json; charset=utf-8',
                schemaId: 'CreateUserBody',
                value: CreateUserBody(name: 'Ada'),
                encoder: CreateUserBody.toJson,
              ),
              abortTrigger: abortTrigger,
            ),
          );

      expect(response.isSuccess, isTrue);
      expect(response.status, 201);
      expect(response.contentType, 'application/json; charset=utf-8');
      expect(response.headers, {'x-response-id': 'res_1'});
      expect(response.rawBody, jsonEncode({'id': '42', 'name': 'Ada'}));
      expect(response.data, const UserDto(id: '42', name: 'Ada'));
      expect(response.requireData, const UserDto(id: '42', name: 'Ada'));
      expect(response.error, isNull);
    });

    test('combines abort triggers with timeout triggers', () async {
      final abortCompleter = Completer<void>();
      final transport = _FakeTransport(
        onSend: (request) async {
          expect(request.abortTrigger, isNotNull);
          abortCompleter.complete();
          await request.abortTrigger;
          return const DartEdgeClientResponse(
            status: 204,
            contentType: 'text/plain; charset=utf-8',
          );
        },
      );
      final client = _TestClient(
        baseUri: Uri.parse('https://api.example.test/v1'),
        transport: transport,
      );

      final response = await client.invoke<Object?, Never, Never, Never, Never>(
        DartEdgeClientInvocation<Object?, Never, Never, Never, Never>(
          method: HttpMethod.delete,
          pathTemplate: '/jobs/1',
          success: const DartEdgeClientResponseSpec<Object?>(
            status: 204,
            contentType: 'text/plain; charset=utf-8',
          ),
          abortTrigger: abortCompleter.future,
          timeout: const Duration(minutes: 1),
        ),
      );

      expect(response.status, 204);
    });

    test('uses timeout triggers when no abort trigger is supplied', () async {
      final transport = _FakeTransport(
        onSend: (request) async {
          expect(request.abortTrigger, isNotNull);
          await request.abortTrigger;
          return const DartEdgeClientResponse(
            status: 204,
            contentType: 'text/plain; charset=utf-8',
          );
        },
      );
      final client = _TestClient(
        baseUri: Uri.parse('https://api.example.test/v1'),
        transport: transport,
      );

      final response = await client.invoke<Object?, Never, Never, Never, Never>(
        DartEdgeClientInvocation<Object?, Never, Never, Never, Never>(
          method: HttpMethod.get,
          pathTemplate: '/jobs/1',
          success: const DartEdgeClientResponseSpec<Object?>(
            status: 204,
            contentType: 'text/plain; charset=utf-8',
          ),
          timeout: Duration.zero,
        ),
      );

      expect(response.status, 204);
    });

    test('builds multipart form-data requests', () async {
      var openedFileStream = false;
      final progressEvents = <DartEdgeMultipartUploadProgress>[];
      final transport = _FakeTransport(
        onSend: (request) async {
          expect(request.method, HttpMethod.post);
          expect(request.uri, Uri.parse('https://api.example.test/v1/uploads'));
          expect(request.headers['content-type'], startsWith('multipart/form-data; boundary='));
          expect(request.body, isNull);
          expect(request.bodyBytes, isNull);
          expect(request.bodyStream, isNotNull);
          expect(openedFileStream, isFalse);
          final text = utf8.decode(await _collectStreamBytes(request.bodyStream!));
          expect(openedFileStream, isTrue);
          expect(request.bodyStreamLength, utf8.encode(text).length);
          expect(progressEvents, isNotEmpty);
          expect(progressEvents.last.bytesSent, request.bodyStreamLength);
          expect(progressEvents.last.totalBytes, request.bodyStreamLength);
          expect(progressEvents.last.fraction, 1);
          expect(text, contains('name="workspace_id"'));
          expect(text, contains('workspace_1'));
          expect(text, contains('name="persist"'));
          expect(text, contains('true'));
          expect(text, contains('name="file"; filename="voice.wav"'));
          expect(text, contains('Content-Type: audio/wav'));
          expect(text, contains('abc'));

          return const DartEdgeClientResponse(
            status: 204,
            contentType: 'text/plain; charset=utf-8',
          );
        },
      );
      final client = _TestClient(
        baseUri: Uri.parse('https://api.example.test/v1'),
        transport: transport,
      );

      await client.invoke<Object?, Never, Never, Never, UploadClientBody>(
        DartEdgeClientInvocation<Object?, Never, Never, Never, UploadClientBody>(
          method: HttpMethod.post,
          pathTemplate: '/uploads',
          success: const DartEdgeClientResponseSpec<Object?>(
            status: 204,
            contentType: 'text/plain; charset=utf-8',
          ),
          body: DartEdgeClientRequestBody<UploadClientBody>(
            contentType: 'multipart/form-data',
            value: UploadClientBody(
              workspaceId: 'workspace_1',
              persist: true,
              file: MultipartUploadFile.stream(
                filename: 'voice.wav',
                contentType: 'audio/wav',
                openRead: () {
                  openedFileStream = true;
                  return Stream.value(utf8.encode('abc'));
                },
                length: 3,
              ),
            ),
            encoder: (value) => value.toMultipartFormData(),
          ),
          onMultipartUploadProgress: progressEvents.add,
        ),
      );
    });

    test('returns documented error response objects', () async {
      final client = _TestClient(
        baseUri: Uri.parse('https://api.example.test'),
        transport: _FakeTransport(
          onSend: (_) async => DartEdgeClientResponse(
            status: 401,
            contentType: 'application/json; charset=utf-8',
            headers: const {'www-authenticate': 'Bearer'},
            body: jsonEncode({'error': 'unauthorized'}),
          ),
        ),
      );

      final response = await client.invoke<UserDto, Never, Never, Never, Never>(
        const DartEdgeClientInvocation<UserDto, Never, Never, Never, Never>(
          method: HttpMethod.get,
          pathTemplate: '/me',
          success: DartEdgeClientResponseSpec<UserDto>(
            status: 200,
            contentType: 'application/json; charset=utf-8',
            schemaId: 'UserDto',
            decoder: UserDto.decode,
          ),
          errors: [DartEdgeClientErrorSpec(status: 401, code: 'unauthorized')],
        ),
      );

      expect(response.isSuccess, isFalse);
      expect(response.data, isNull);
      expect(response.status, 401);
      expect(response.contentType, 'application/json; charset=utf-8');
      expect(response.rawBody, jsonEncode({'error': 'unauthorized'}));
      expect(response.error?.status, 401);
      expect(response.error?.code, 'unauthorized');
      expect(response.error?.kind, DartEdgeClientErrorKind.documented);
      expect(response.error?.contentType, 'application/json; charset=utf-8');
      expect(response.error?.headers, {'www-authenticate': 'Bearer'});
      expect(response.error?.rawBody, jsonEncode({'error': 'unauthorized'}));
      expect(response.error?.body, {'error': 'unauthorized'});
      expect(() => response.requireData, throwsStateError);
    });

    test('returns unknown error response objects for undeclared statuses', () async {
      final client = _TestClient(
        baseUri: Uri.parse('https://api.example.test'),
        transport: _FakeTransport(
          onSend: (_) async => const DartEdgeClientResponse(
            status: 503,
            contentType: 'text/plain; charset=utf-8',
            body: 'service unavailable',
          ),
        ),
      );

      final response = await client.invoke<String, Never, Never, Never, Never>(
        const DartEdgeClientInvocation<String, Never, Never, Never, Never>(
          method: HttpMethod.get,
          pathTemplate: '/health',
          success: DartEdgeClientResponseSpec<String>(
            status: 200,
            contentType: 'text/plain; charset=utf-8',
          ),
        ),
      );

      expect(response.isSuccess, isFalse);
      expect(response.status, 503);
      expect(response.data, isNull);
      expect(response.error?.status, 503);
      expect(response.error?.code, isNull);
      expect(response.error?.kind, DartEdgeClientErrorKind.unknownStatus);
      expect(response.error?.body, 'service unavailable');
      expect(() => response.requireData, throwsStateError);
    });

    test('decodes binary responses from transport body bytes', () async {
      final bytes = Uint8List.fromList([0, 255, 1, 128, 2]);
      final client = _TestClient(
        baseUri: Uri.parse('https://api.example.test'),
        transport: _FakeTransport(
          onSend: (_) async =>
              DartEdgeClientResponse(status: 200, contentType: 'audio/wav', bodyBytes: bytes),
        ),
      );

      final response = await client.invoke<Uint8List, Never, Never, Never, Never>(
        const DartEdgeClientInvocation<Uint8List, Never, Never, Never, Never>(
          method: HttpMethod.get,
          pathTemplate: '/tone.wav',
          success: DartEdgeClientResponseSpec<Uint8List>(status: 200, contentType: 'audio/wav'),
        ),
      );

      expect(response.isSuccess, isTrue);
      expect(response.rawBodyBytes, bytes);
      expect(response.data, bytes);
      expect(response.requireData, bytes);
    });

    test('returns streamed success responses without buffering', () async {
      var listened = false;
      final client = _TestClient(
        baseUri: Uri.parse('https://api.example.test'),
        transport: _FakeTransport(
          onSend: (_) async => throw StateError('send should not be used'),
          onSendStream: (request) async {
            expect(request.method, HttpMethod.get);
            expect(request.uri, Uri.parse('https://api.example.test/events'));
            return DartEdgeClientStreamedResponse(
              status: 200,
              contentType: 'text/event-stream; charset=utf-8',
              headers: const {'cache-control': 'no-cache'},
              bodyStream: Stream<List<int>>.fromIterable([utf8.encode('data: alpha\n\n')])
                  .map((chunk) {
                    listened = true;
                    return chunk;
                  }),
            );
          },
        ),
      );

      final response = await client.invokeStream<Never, Never, Never, Never>(
        const DartEdgeClientInvocation<Object?, Never, Never, Never, Never>(
          method: HttpMethod.get,
          pathTemplate: '/events',
          success: DartEdgeClientResponseSpec<Object?>(
            status: 200,
            contentType: 'text/event-stream; charset=utf-8',
          ),
        ),
      );

      expect(response.isSuccess, isTrue);
      expect(response.headers, {'cache-control': 'no-cache'});
      expect(listened, isFalse);
      expect(utf8.decode(await _collectStreamBytes(response.requireBodyStream)), 'data: alpha\n\n');
      expect(listened, isTrue);
    });

    test('buffers streamed non-success responses as client errors', () async {
      final client = _TestClient(
        baseUri: Uri.parse('https://api.example.test'),
        transport: _FakeTransport(
          onSend: (_) async => throw StateError('send should not be used'),
          onSendStream: (_) async => DartEdgeClientStreamedResponse(
            status: 401,
            contentType: 'application/json; charset=utf-8',
            bodyStream: Stream.value(utf8.encode('{"error":"unauthorized"}')),
          ),
        ),
      );

      final response = await client.invokeStream<Never, Never, Never, Never>(
        const DartEdgeClientInvocation<Object?, Never, Never, Never, Never>(
          method: HttpMethod.get,
          pathTemplate: '/events',
          success: DartEdgeClientResponseSpec<Object?>(
            status: 200,
            contentType: 'text/event-stream; charset=utf-8',
          ),
          errors: [DartEdgeClientErrorSpec(status: 401, code: 'unauthorized')],
        ),
      );

      expect(response.isSuccess, isFalse);
      expect(response.error?.kind, DartEdgeClientErrorKind.documented);
      expect(response.error?.code, 'unauthorized');
      expect(response.error?.body, {'error': 'unauthorized'});
      expect(() => response.requireBodyStream, throwsStateError);
    });

    test('builds websocket connection requests', () async {
      final transport = _FakeWebSocketTransport(
        onConnect: (request) async {
          expect(
            request.uri,
            Uri.parse(
              'wss://api.example.test/v1/rooms/42/socket'
              '?includeDeleted=true&tags=alpha&tags=beta',
            ),
          );
          expect(request.headers, {'authorization': 'Bearer token'});
          expect(request.protocols, ['chat']);
          return const _FakeWebSocket();
        },
      );
      final client = _TestClient(
        baseUri: Uri.parse('https://api.example.test/v1'),
        transport: _FakeTransport(
          onSend: (_) => throw StateError('HTTP transport should not run.'),
        ),
        webSocketTransport: transport,
        defaultHeaders: const {'authorization': 'Bearer token'},
      );

      await client.connectWebSocket<RoomPath, UserQuery?, Never>(
        DartEdgeClientWebSocketInvocation<RoomPath, UserQuery?, Never>(
          pathTemplate: '/rooms/<id>/socket',
          params: const DartEdgeClientRequestValue<RoomPath>(
            value: RoomPath(id: '42'),
            encoder: RoomPath.toJson,
          ),
          query: DartEdgeClientRequestValue<UserQuery?>(
            value: UserQuery(includeDeleted: true, tags: ['alpha', 'beta']),
            encoder: (value) => value == null ? null : UserQuery.toJson(value),
          ),
          protocols: ['chat'],
        ),
      );
    });

    test('builds webtransport connection requests', () async {
      final transport = _FakeWebTransportTransport(
        onConnect: (request) async {
          expect(request.uri, Uri.parse('https://api.example.test/v1/rooms/42/transport'));
          expect(request.headers, {'authorization': 'Bearer token'});
          return const _FakeWebTransportSession();
        },
      );
      final client = _TestClient(
        baseUri: Uri.parse('https://api.example.test/v1'),
        transport: _FakeTransport(
          onSend: (_) => throw StateError('HTTP transport should not run.'),
        ),
        webTransportTransport: transport,
        defaultHeaders: const {'authorization': 'Bearer token'},
      );

      await client.connectWebTransport<RoomPath, Never, Never>(
        const DartEdgeClientWebTransportInvocation<RoomPath, Never, Never>(
          pathTemplate: '/rooms/<id>/transport',
          params: DartEdgeClientRequestValue<RoomPath>(
            value: RoomPath(id: '42'),
            encoder: RoomPath.toJson,
          ),
        ),
      );
    });
  });
}

final class _TestClient extends DartEdgeHttpClientBase {
  const _TestClient({
    required super.baseUri,
    required super.transport,
    super.webSocketTransport,
    super.webTransportTransport,
    super.defaultHeaders,
  });
}

final class _FakeTransport implements DartEdgeClientTransport {
  const _FakeTransport({required this.onSend, this.onSendStream});

  final Future<DartEdgeClientResponse> Function(DartEdgeClientRequest request) onSend;
  final Future<DartEdgeClientStreamedResponse> Function(DartEdgeClientRequest request)?
  onSendStream;

  @override
  Future<DartEdgeClientResponse> send(DartEdgeClientRequest request) {
    return onSend(request);
  }

  @override
  Future<DartEdgeClientStreamedResponse> sendStream(DartEdgeClientRequest request) {
    final onSendStream = this.onSendStream;
    if (onSendStream == null) {
      throw UnsupportedError('No streaming response configured.');
    }
    return onSendStream(request);
  }
}

Future<List<int>> _collectStreamBytes(Stream<List<int>> stream) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

final class _FakeWebSocketTransport implements DartEdgeClientWebSocketTransport {
  const _FakeWebSocketTransport({required this.onConnect});

  final Future<DartEdgeClientWebSocket> Function(DartEdgeClientWebSocketRequest request) onConnect;

  @override
  Future<DartEdgeClientWebSocket> connect(DartEdgeClientWebSocketRequest request) {
    return onConnect(request);
  }
}

final class _FakeWebSocket implements DartEdgeClientWebSocket {
  const _FakeWebSocket();

  @override
  Stream<WebSocketMessage> get messages => const Stream.empty();

  @override
  Future<void> close([int? code, String? reason]) async {}

  @override
  Future<void> sendBinary(List<int> value) async {}

  @override
  Future<void> sendJson(Object? value) async {}

  @override
  Future<void> sendText(String value) async {}
}

final class _FakeWebTransportTransport implements DartEdgeClientWebTransportTransport {
  const _FakeWebTransportTransport({required this.onConnect});

  final Future<DartEdgeClientWebTransportSession> Function(
    DartEdgeClientWebTransportRequest request,
  )
  onConnect;

  @override
  Future<DartEdgeClientWebTransportSession> connect(DartEdgeClientWebTransportRequest request) {
    return onConnect(request);
  }
}

final class _FakeWebTransportSession implements DartEdgeClientWebTransportSession {
  const _FakeWebTransportSession();

  @override
  Stream<Uint8List> get datagrams => const Stream.empty();

  @override
  IncomingWebTransportReceiveStreams get incomingStreams =>
      const IncomingWebTransportReceiveStreams();

  @override
  Future<WebTransportSendStream> openUnidirectionalStream({int? sendOrder}) =>
      throw UnsupportedError('Not used by this generated-client test.');

  @override
  Future<WebTransportBidirectionalStream> openBidirectionalStream({int? sendOrder}) =>
      throw UnsupportedError('Not used by this generated-client test.');

  @override
  Stream<Uint8List> get streams => const Stream.empty();

  @override
  Future<void> close([int? code, String? reason]) async {}

  @override
  Future<void> sendDatagram(List<int> value) async {}

  @override
  Future<void> sendStream(List<int> value) async {}
}

final class RoomPath {
  const RoomPath({required this.id});

  final String id;

  static Map<String, Object?> toJson(RoomPath value) => {'id': value.id};
}

final class UserPath {
  const UserPath({required this.id});

  final String id;

  static Map<String, Object?> toJson(UserPath value) => {'id': value.id};
}

final class UserQuery {
  const UserQuery({required this.includeDeleted, required this.tags});

  final bool includeDeleted;
  final List<String> tags;

  static Map<String, Object?> toJson(UserQuery value) => {
    'includeDeleted': value.includeDeleted,
    'tags': value.tags,
  };
}

final class RequestHeaders {
  const RequestHeaders({required this.requestId});

  final String requestId;

  static Map<String, Object?> toJson(RequestHeaders value) => {'x-request-id': value.requestId};
}

final class CreateUserBody {
  const CreateUserBody({required this.name});

  final String name;

  static Map<String, Object?> toJson(CreateUserBody value) => {'name': value.name};
}

final class UploadClientBody {
  const UploadClientBody({required this.workspaceId, required this.persist, required this.file});

  final String workspaceId;
  final bool persist;
  final MultipartUploadFile file;

  MultipartFormData toMultipartFormData() {
    return MultipartFormData(
      fields: [
        MultipartFormField(name: 'workspace_id', value: workspaceId),
        MultipartFormField(name: 'persist', value: persist.toString()),
      ],
      files: [file.asFile('file')],
    );
  }
}

final class UserDto {
  const UserDto({required this.id, required this.name});

  final String id;
  final String name;

  static UserDto decode(Object? value) {
    return UserDto.fromJson(value! as Map<String, Object?>);
  }

  static UserDto fromJson(Map<String, Object?> map) {
    return UserDto(id: map['id']! as String, name: map['name']! as String);
  }

  @override
  bool operator ==(Object other) {
    return other is UserDto && other.id == id && other.name == name;
  }

  @override
  int get hashCode => Object.hash(id, name);
}

final class TestServices {
  const TestServices();
}
