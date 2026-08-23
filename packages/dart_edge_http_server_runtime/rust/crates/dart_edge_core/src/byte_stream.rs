use std::ffi::c_void;
use std::mem::size_of;

use crate::{NativeBytes, NativeOwnedBytes};

/// ABI version implemented by [`NativeByteStream`].
pub const NATIVE_BYTE_STREAM_ABI_VERSION: u32 = 1;

/// A stream read produced one byte chunk.
pub const NATIVE_BYTE_STREAM_READ_CHUNK: i32 = 0;
/// A stream read reached the end of the stream.
pub const NATIVE_BYTE_STREAM_READ_DONE: i32 = 1;
/// A stream read failed.
pub const NATIVE_BYTE_STREAM_READ_ERROR: i32 = 2;
/// A stream read was canceled.
pub const NATIVE_BYTE_STREAM_READ_CANCELED: i32 = 3;

/// Result returned by one native byte-stream read.
///
/// The producer owns this value and its fields. Consumers must call the
/// stream's `free_read` callback exactly once after copying or otherwise
/// taking ownership of the bytes they need.
#[repr(C)]
pub struct NativeByteStreamRead {
    /// One of the `NATIVE_BYTE_STREAM_READ_*` status constants.
    pub status: i32,
    /// Owned chunk bytes when `status` is `NATIVE_BYTE_STREAM_READ_CHUNK`.
    pub bytes: NativeOwnedBytes,
    /// Borrowed UTF-8 diagnostic bytes when `status` is an error.
    pub error: NativeBytes,
}

/// Pulls the next result from a native byte stream.
pub type NativeByteStreamNext =
    unsafe extern "C" fn(context: *mut c_void) -> *mut NativeByteStreamRead;

/// Cancels a native byte stream. This operation must be idempotent.
pub type NativeByteStreamCancel = unsafe extern "C" fn(context: *mut c_void);

/// Releases one result returned by [`NativeByteStreamNext`].
pub type NativeByteStreamFreeRead = unsafe extern "C" fn(value: *mut NativeByteStreamRead);

/// Releases the producer context. This operation must be idempotent and must
/// also stop an active stream when it has not already completed.
pub type NativeByteStreamRelease = unsafe extern "C" fn(context: *mut c_void);

/// Versioned native pull-stream descriptor shared across native assets.
///
/// The descriptor is copied across the FFI boundary. Its opaque context stays
/// owned by the producer until `release` is called exactly once. At most one
/// `next` call may be active at a time.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct NativeByteStream {
    /// ABI version of this descriptor.
    pub abi_version: u32,
    /// Size of this descriptor in bytes, allowing compatible extension.
    pub struct_size: usize,
    /// Opaque producer-owned context.
    pub context: *mut c_void,
    /// Pulls one chunk, terminal result, or error.
    pub next: Option<NativeByteStreamNext>,
    /// Requests cancellation without releasing the context.
    pub cancel: Option<NativeByteStreamCancel>,
    /// Releases a result returned by `next`.
    pub free_read: Option<NativeByteStreamFreeRead>,
    /// Releases the context and cancels it if still active.
    pub release: Option<NativeByteStreamRelease>,
}

impl NativeByteStream {
    /// Returns whether all required fields satisfy the current ABI.
    pub fn is_valid(&self) -> bool {
        self.abi_version == NATIVE_BYTE_STREAM_ABI_VERSION
            && self.struct_size >= size_of::<Self>()
            && self.next.is_some()
            && self.free_read.is_some()
            && self.release.is_some()
    }
}

// The producer contract requires the context and callbacks to be safe for
// serialized access from a foreign worker thread.
unsafe impl Send for NativeByteStream {}
unsafe impl Sync for NativeByteStream {}

#[cfg(test)]
mod tests {
    use super::*;

    unsafe extern "C" fn next(_: *mut c_void) -> *mut NativeByteStreamRead {
        std::ptr::null_mut()
    }

    unsafe extern "C" fn cancel(_: *mut c_void) {}
    unsafe extern "C" fn free_read(_: *mut NativeByteStreamRead) {}
    unsafe extern "C" fn release(_: *mut c_void) {}

    #[test]
    fn validates_the_versioned_stream_descriptor() {
        let stream = NativeByteStream {
            abi_version: NATIVE_BYTE_STREAM_ABI_VERSION,
            struct_size: size_of::<NativeByteStream>(),
            context: std::ptr::dangling_mut::<c_void>(),
            next: Some(next),
            cancel: Some(cancel),
            free_read: Some(free_read),
            release: Some(release),
        };

        assert!(stream.is_valid());
        assert!(
            !NativeByteStream {
                abi_version: NATIVE_BYTE_STREAM_ABI_VERSION + 1,
                ..stream
            }
            .is_valid()
        );
    }
}
