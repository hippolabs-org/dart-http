# Dart HTTP Agent Guide

- Keep HTTP, routing, WebSocket, WebTransport, client, and server contracts in
  this repository.
- Keep SQL and other service-domain APIs out of the HTTP core.
- Generic native ownership descriptors belong in Native Exchange; HTTP-specific
  response and body semantics belong here.
- Preserve `resolution: workspace` for every Dart package.
- Native packages own their build hook, Rust crate, header, and generated FFI
  bindings.
- Prefer native buffer/stream transfer for hot payload paths and make Dart
  copies explicit.
- Keep all runtime crates under the owning Dart package's `rust/` directory;
  do not create a repository-level Cargo workspace.
- Run `dart run melos run ci` and the runtime package's Cargo tests after shared
  changes.
