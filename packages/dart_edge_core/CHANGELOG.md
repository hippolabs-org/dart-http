## Unreleased

## 0.3.45

- Add generated-client operation metadata and cancellable request handles.
- Move the FFI-backed `NativeBinaryPayloadLease` implementation to
  `dart_edge_native_bridge` so the core contract package remains
  web-compilable.
- Remove the now-unused `ffigen` development dependency.

## 0.3.42

- Add long-lived unidirectional and bidirectional stream handles to generated
  WebTransport client sessions.
- Make QUIC protocol stream identifiers optional for browser clients, which do
  not expose them.

## 0.3.41

- Add transport-agnostic contracts for persistent WebTransport
  unidirectional and bidirectional streams.
- Add `BinaryPayloadLease` for single-owner binary transport payloads.
- Add lazy-copy and leased receive/send APIs for WebSocket binary frames and
  WebTransport datagrams and reliable stream payloads.

## 0.3.40

- Add typed single-byte HTTP range parsing and resolution for closed,
  open-ended, and suffix ranges.
- Add standard `206` streaming and `416` response metadata helpers.

## 0.3.39

- Add response content-length parsing and download progress tracking for
  generated-client streamed responses.

## 0.3.38

- Let binary stream responses release pre-acquired resources on every runtime
  exit path.

## 0.3.37

- Add `BinaryStreamResponse` and `ResponseBuilder.binaryStream` for encoded
  response bodies with transport-level backpressure.

## 0.3.36

- Describe `ResponseSpec.binary()` payloads with an OpenAPI-compatible
  `string` schema using the `binary` format.

## 0.3.35

- Require `json_schema` 0.1.2.

## 0.3.34

- Depend on `json_schema` 0.1.1 and remove the legacy JSON Schema and
  `JsonEncodable` re-exports.

## 0.3.33

- Keep HTTP-only model annotations in Dart Edge as `@FromHttpSchema` and
  `@FromMultipartSchema`.

## 0.3.32

- Add inclusive `minimum` and `maximum` constraints to integer and number JSON
  schemas.

## 0.3.31

- Add `SqlColumnBase` for heterogeneous SQL table column metadata.

## 0.3.30

- Add `SqlKeyManifestEntry` for generated SQL key manifests.

## 0.3.29

- Add `SqlRow` helpers for reading values by typed SQL column projection aliases.

## 0.3.28

- Add reusable API contract endpoint and metadata-only route helpers.

## 0.3.26

- Add `SqlVector` as a shared pgvector value contract.
- Add `SqlDecimal` as a shared lossless decimal value contract.

## 0.3.24

- Add generated-client streamed response contracts for SSE and other long-lived
  HTTP response streams.

## 0.3.22

- Add streamed generated-client request body contracts.
- Add generated-client request timeout contracts that compose with abort
  triggers.
- Stream generated-client multipart form-data uploads without buffering file
  contents into memory.
- Add generated-client multipart upload progress contracts.
- Preserve multipart request content length when every upload file length is
  known.

## 0.3.19

- Add a reusable long-lived isolate request worker for native-backed services.

## 0.3.17

- Add first-class HTTP request observer contracts for route-level
  instrumentation.

## 0.3.16

- Add multipart form-data body contracts and `@FromMultipartSchema`.
- Add schema-backed multipart request body decoder support.
- Add generated-client multipart upload file and byte request body contracts.

## 0.3.13

- Add WebSocket route query schema and query decoder options.

## 0.3.11

- Add WebTransport core route, context, generated-client, datagram, and
  reliable stream payload contracts.

## 0.3.10

- Add binary response contracts with `RawResponse.binary`,
  `ResponseSpec.binary`, generated-client response bytes, and response-builder
  binary helpers.

## 0.3.9

- Add optional database type metadata to SQL column descriptors.

## 0.3.8

- Add route-local decoders for path parameters and query parameters.

## 0.2.0

- Update package constraints for the native HTTP routing and shared core API changes.

## 0.1.0

- Initial internal release.
## 0.3.44

- Add configurable pending-message and pending-byte limits to WebSocket and
  WebTransport route options.
- Expose native binary payload leases from the shared transport layer so
  synchronous consumers can borrow native pointers without runtime coupling.
