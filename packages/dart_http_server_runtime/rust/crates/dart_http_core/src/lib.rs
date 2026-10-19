//! Shared C-compatible FFI primitives for Dart HTTP native crates.
//!
//! The types in this crate are intentionally narrow. They model byte buffers
//! and string key/value pairs that cross the Dart FFI boundary, plus helpers
//! for converting between owned Rust values and borrowed C-compatible structs.
//!
//! `NativeBytes` and `NativePair` are borrowed views. They must not outlive the
//! Rust values that created them.

#![deny(missing_docs)]

mod bytes;
mod owned;
mod pairs;

pub use bytes::{NativeBytes, read_native_bytes, read_native_str, read_native_string};
pub use owned::OwnedBytes;
pub use pairs::{
    NativePair, OwnedPair, boxed_pairs_ptr, native_pairs_from_owned, owned_pairs_from_map,
    read_pairs_vec,
};
