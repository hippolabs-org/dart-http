//! Shared C-compatible FFI primitives for Dart Edge native crates.
//!
//! The types in this crate are intentionally narrow. They model byte buffers
//! and string key/value pairs that cross the Dart FFI boundary, plus helpers
//! for converting between owned Rust values and borrowed C-compatible structs.
//!
//! `NativeBytes` and `NativePair` are borrowed views. They must not outlive the
//! Rust values that created them. `NativeOwnedBytes` transfers a boxed byte
//! allocation to the caller and must be returned to [`free_owned_bytes`].

#![deny(missing_docs)]

mod byte_stream;
mod bytes;
mod dart_api;
mod job_pool;
mod owned;
mod pairs;
mod slice;
mod status;
mod string;

pub use byte_stream::{
    NATIVE_BYTE_STREAM_ABI_VERSION, NATIVE_BYTE_STREAM_READ_CANCELED,
    NATIVE_BYTE_STREAM_READ_CHUNK, NATIVE_BYTE_STREAM_READ_DONE, NATIVE_BYTE_STREAM_READ_ERROR,
    NativeByteStream, NativeByteStreamCancel, NativeByteStreamFreeRead, NativeByteStreamNext,
    NativeByteStreamRead, NativeByteStreamRelease,
};
pub use bytes::{
    NativeBytes, NativeOwnedBytes, read_native_bytes, read_native_str, read_native_string,
};
pub use dart_api::{DartNativePort, NativeCompletionPort, initialize_dart_api_dl};
pub use job_pool::{NativeJobPoll, NativeJobPool, NativeJobPoolMetrics, NativeJobSubmitError};
pub use owned::{OwnedBytes, free_owned_bytes, into_native_owned_bytes};
pub use pairs::{
    NativePair, OwnedPair, boxed_pairs_ptr, native_pairs_from_owned, owned_pairs_from_map,
    read_pairs_map, read_pairs_vec,
};
pub use slice::{NativeSlice, read_native_slice};
pub use status::{NativeResult, NativeStatus};
pub use string::{NativeString, read_native_string_owned, read_native_string_ref};
