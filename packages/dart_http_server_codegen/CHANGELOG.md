## 0.6.0

- Generate public classes directly from `@GenerateHttpModel` schema constants.
  Existing typedef annotations and generic model declarations remain supported.
- **Breaking:** Generated clients reuse typed core operations by default instead
  of emitting an endpoint-specific public class for every method. Normal calls,
  `.start`, `.info` and binary `.stream` keep their signatures. Set
  `useSharedOperations: false` to retain legacy operation types and constructors.
- Keep endpoint-specific output for uncommon argument signatures. Share stable
  metadata/codecs between invocations and preserve multipart upload progress.
- Use the same JSON object model emitter for contract and client models, while
  retaining distinct inbound multipart and outbound upload models.
- Emit required named parameters first and sorted directives. Exempt generated
  code only from the optional dot-shorthand style diagnostic.
- Require `dart_http_core` 0.4.1.

## 0.5.0

- **Breaking:** Require `dart_http_core` 0.4.0.
- Fix generated client models for nullable array items: decode them with a
  null check and encode them as nullable.
- Behaviour change: encode date-time fields as UTC
  (`toUtc().toIso8601String()`) in generated clients and `@FromHttpSchema`
  models, so local `DateTime` values keep their instant.
- Use the shared `jsonSchemaRouteId` from `dart_http_core`.
- Require `analyzer` 14.5 and `source_gen` 4.3.
- Stop generating client operations for native HTTP route mounts, which were
  removed from `dart_http_core`.

## 0.4.3

- Generate `decodeQuery` for schema-backed models with scalar query fields.
- Require `dart_http_core` 0.3.61 for schema-aware query conversion.

## 0.4.2

- Decode top-level JSON arrays item by item in generated clients, including
  arrays of external schema model types.
- Omit the JSON Schema import when a generated client has no local models.

## 0.4.1

- Generate explicit server-sent event delivery semantics from
  `ResponseSpec.sse()` contracts.
- Require `dart_http_core` 0.3.48.

## 0.4.0

- **Breaking:** Adopt the new Dart HTTP package, builder, and generated API
  namespace.
- **Breaking:** Generate callable HTTP operation objects with `info`, `call`,
  and `start`, plus WebSocket and WebTransport operation objects with `info`
  and `connect`.
- Move binary streaming from an operation-name `Stream` suffix to the generated
  operation object's `stream` method.

## 0.3.41

- Generate an additive streamed-response method alongside each buffered
  `Uint8List` client method.
- Require `dart_http_core` 0.3.39.

## 0.3.40

- Infer `Uint8List` for client operation schemas using the JSON Schema
  `binary` string format.
- Require `dart_http_core` 0.3.36.

## 0.3.39

- Require `json_schema` 0.1.2.

## 0.3.38

- Require `json_schema` 0.1.1 and import JSON contracts directly in generated
  clients and models.

## 0.3.37

- Support `@FromHttpSchema` for generated Dart HTTP request and response
  models, keeping HTTP status metadata out of portable `@FromSchema`.
- Reserve `@FromSchema` model generation for the standalone `json_schema_gen`
  builder.

## 0.3.36

- Preserve JSON Schema `minimum` and `maximum` constraints in generated model
  schemas.
- Require `dart_http_core` 0.3.32.

## 0.3.33

- Apply configured builder formatter options to the final generated shared part
  output.
- Support formatter options for generated client libraries, bindings, models,
  and file emission.

## 0.3.30

- Generate streamed client methods for `ResponseSpec.sse()` routes.
- Require `dart_http_core` 0.3.23.

## 0.3.27

- Generate optional multipart upload progress callbacks for multipart client
  routes.
- Generate optional request timeout parameters for HTTP client routes.
- Require `dart_http_core` 0.3.22.

## 0.3.24

- Generate typed multipart form-data body models from `@FromMultipartSchema`.
- Generate multipart client body DTOs with `MultipartUploadFile` fields and
  `toMultipartFormData()` encoders.
- Map `string(format: binary)` multipart fields to `MultipartFile`.
- Require `dart_http_core` 0.3.16.

## 0.3.20

- Generate WebSocket client query parameters from `WebSocketOptions.query`.
- Discover WebSocket query schemas from router registries for generated client
  models.
- Require `dart_http_core` 0.3.13.

## 0.3.18

- Generate WebTransport client connection methods and support sessions with
  datagrams and reliable stream payloads.
- Require `dart_http_core` 0.3.11.

## 0.3.17

- Generate `Uint8List` client bindings for binary response contracts.
- Require `dart_http_core` 0.3.10.

## 0.3.16

- Preserve route-local path parameter and query parameter decoders when
  deriving effective route options.
- Require `dart_http_core` 0.3.8.

## 0.3.8

- Update `dart_http_server_runtime` constraint for rebuilt native artifacts.

## 0.3.7

- Update `dart_http_server_runtime` constraint for Linux arm64 native
  artifacts.

## 0.3.6

- Update `dart_http_server_runtime` constraint for prebuilt native asset
  support.

## 0.3.0

- Declare internal Dart HTTP dependencies with the internal hosted registry.

## 0.2.0

- Update package constraints for the native HTTP routing and shared core API changes.

## 0.1.0

- Initial internal release.
