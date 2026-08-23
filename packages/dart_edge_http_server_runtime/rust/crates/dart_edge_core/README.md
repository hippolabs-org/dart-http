# dart_edge_core

Shared Rust FFI primitives for Dart Edge native asset crates.

This crate contains only low-level C-compatible value types and ownership
helpers used by native libraries that are loaded from Dart through FFI. It is
published separately from the Dart packages so package native asset crates can
depend on it through Cargo instead of relying on monorepo-relative paths.

The public structs are intentionally small and `#[repr(C)]` or
`#[repr(transparent)]`. They are suitable for generated Dart FFI bindings, but
they do not own the memory they point at unless explicitly documented.

Included primitives:

- borrowed and owned byte buffers
- borrowed UTF-8 string views
- borrowed key/value pairs
- borrowed typed slices for Rust-side FFI helpers
- a small status/result envelope for future native APIs
- a bounded native worker-thread pool for package-specific native jobs, with
  queue and completion metrics
