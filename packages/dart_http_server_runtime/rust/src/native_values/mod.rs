//! C-compatible byte and key/value views shared with Dart over FFI.
//!
//! `NativeBytes` and `NativePair` are borrowed views. They must not outlive the
//! Rust values that created them.

mod bytes;
mod owned;
mod pairs;

pub use bytes::{NativeBytes, read_native_bytes};
pub use owned::OwnedBytes;
pub use pairs::{
    NativePair, OwnedPair, boxed_pairs_ptr, native_pairs_from_owned, owned_pairs_from_map,
    read_pairs_vec,
};
