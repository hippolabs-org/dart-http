## Unreleased

## 0.3.38

- Use the shared `NativeBinaryPayloadLease` from `dart_edge_native_bridge`
  instead of exporting an HTTP-specific implementation.
- Require `dart_edge_native_bridge` 0.1.5.

## 0.3.37

- Enforce configurable pending-message and pending-byte ceilings for native
  WebSocket and WebTransport ingress queues.
- Close overloaded WebSocket sessions with 1013 and overloaded WebTransport
  sessions with the application overload code instead of accumulating frames.
- Move the native binary payload lease contract into `dart_edge_core` for
  synchronous cross-package borrowed-pointer processing.
- Bump the native artifact version to 0.1.20 and require `dart_edge_core`
  0.3.44.

## 0.3.36

- Add long-lived unidirectional and bidirectional WebTransport stream handles
  with incremental native-leased receive chunks, flow-controlled writes,
  graceful FIN, reset, stop, stream IDs, and terminal errors.
- Bump the native artifact version to 0.1.19 for the persistent stream ABI.
- Retain native WebSocket and WebTransport message handles as binary payload
  leases instead of eagerly copying their bodies into Dart-managed memory.
- Add borrowed-pointer sends for leased WebSocket binary frames, WebTransport
  datagrams, and WebTransport reliable stream payloads.
- Require `dart_edge_core` 0.3.41.

## 0.3.35

- Add `NativeBinaryStreamResponse.partial` for native `206 Partial Content`
  responses with standard range headers and content length.
- Require `dart_edge_core` 0.3.40.

## 0.3.34

- Add `NativeBinaryStreamResponse` for native producer-to-HTTP streaming
  without routing body chunks through Dart.
- Bump the native artifact version to 0.1.18 for native stream consumption.

## 0.3.33

- Dispose binary streaming response resources after completion, cancellation,
  failure, and native response startup failure.
- Require `dart_edge_core` 0.3.38.

## 0.3.32

- Stream binary response bodies through a backpressured native transport path.
- Require `dart_edge_core` 0.3.37.
- Bump the native artifact version to 0.1.17 for the streaming response ABI.

## 0.3.31

- Document binary response media types with an OpenAPI `string/binary` schema.
- Require `dart_edge_core` 0.3.36.

## 0.3.30

- Add first-class OpenAPI security schemes and global security requirements.
- Add API-key authentication schemes, tag definitions, external documentation,
  contact and license metadata, and server variables.

## 0.3.29

- Require `json_schema` 0.1.2.

## 0.3.26

- Require `json_schema` 0.1.1 and import JSON Schema contracts directly from
  their owning package.

## 0.3.20

- Add first-class Dart HTTP request observers around route dispatch.
- Require `dart_edge_core` 0.3.17.

## 0.3.19

- Decode schema-backed multipart form-data bodies through route-local decoders.
- Expose runtime multipart files through the core `MultipartFile` contract.
- Require `dart_edge_core` 0.3.16.

## 0.3.18

- Add final wildcard route segment support for catch-all HTTP routes.
- Bump the native artifact version to 0.1.11 for the route matcher change.
- Bump the native artifact version to 0.1.12 for Rust 1.95 and dependency
  updates.

## 0.3.17

- Decode WebSocket handshake query parameters through route query schemas and
  route-local query decoders.
- Include WebSocket query schema refs in the native route manifest.
- Require `dart_edge_core` 0.3.13.

## 0.3.15

- Add WebTransport route runtime support over QUIC/HTTP3 with datagram and
  reliable stream payload handling.
- Require `dart_edge_core` 0.3.11.
- Bump the native artifact version to 0.1.10 for the WebTransport ABI.

## 0.3.14

- Send normal HTTP responses through the native runtime as bytes instead of
  UTF-8 strings, enabling true binary responses such as `audio/wav`.
- Require `dart_edge_core` 0.3.10.
- Bump the native artifact version to 0.1.7 for the response ABI change.

## 0.3.13

- Decode path parameters and query parameters with route-local decoders before
  falling back to schema-id codecs.
- Require `dart_edge_core` 0.3.8.

## 0.3.7

- Bump the native artifact version to 0.1.2 for rebuilt prebuilts.
- Require `dart_edge_native_assets` 0.1.2.

## 0.3.5

- Publish Linux arm64 native artifacts.

## 0.3.4

- Use prebuilt Linux and macOS native assets when available, with Rust source
  build fallback.

## 0.3.0

- Declare internal Dart Edge dependencies with the internal hosted registry.

## 0.2.0

- Update package constraints for the native HTTP routing and shared core API changes.

## 0.1.0

- Initial internal release.
