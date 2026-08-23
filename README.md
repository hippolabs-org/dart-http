# Dart HTTP

Protocol-neutral HTTP packages for Dart applications and frameworks maintained by Hippolabs.

This repository owns reusable HTTP contracts, clients, servers, native
runtimes, wire models, and helpers. It deliberately has no dependency on
Hippobase; application frameworks depend on this workspace instead.

Native Exchange is the first-class body ownership boundary. Native producers
can transfer buffers and pull streams directly into the HTTP runtime while Dart
remains the routing and control plane.

CI resolves the private Native Exchange source pin with the organization-level
`HIPPOLABS_REPO_TOKEN` Actions secret until `native_exchange` is published to
`pub.hippolabs.org`.

## Packages

| Package | Description |
| --- | --- |
| [`sse_helpers`](packages/sse_helpers) | Bounded, incremental Server-Sent Events encoding and decoding. |
| `dart_edge_core` | Transport-neutral HTTP, routing, WebSocket, and WebTransport contracts. |
| `dart_edge_http_client` | HTTP and WebSocket transports for generated clients. |
| `dart_edge_http_server` | App-facing HTTP server and helpers. |
| `dart_edge_http_server_codegen` | Route, schema, and client generation. |
| `dart_edge_http_server_runtime` | Rust-backed native HTTP runtime. |

The existing package names are retained during extraction so applications can
migrate repository ownership without an immediate API rename.

## Development

```sh
dart pub get
dart run melos run ci
cargo test --manifest-path packages/dart_edge_http_server_runtime/rust/Cargo.toml
```
