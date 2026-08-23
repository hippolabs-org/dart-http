use std::str::Utf8Error;

/// Borrowed byte view passed across the Dart FFI boundary.
///
/// A null pointer with `len == 0` represents an empty slice. Non-null pointers
/// must point to at least `len` valid bytes for the duration of the native call.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct NativeBytes {
    /// Pointer to the first byte, or null for an empty slice.
    pub ptr: *const u8,
    /// Number of bytes. Negative lengths are treated as invalid by readers.
    pub len: isize,
}

/// Owned byte buffer returned across the Dart FFI boundary.
///
/// Values created by [`crate::into_native_owned_bytes`] transfer ownership of a
/// boxed byte slice to the caller. The same value must eventually be passed to
/// [`crate::free_owned_bytes`] exactly once.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct NativeOwnedBytes {
    /// Pointer to the first byte, or null for an empty allocation.
    pub ptr: *mut u8,
    /// Number of bytes in the allocation.
    pub len: isize,
}

impl Default for NativeBytes {
    fn default() -> Self {
        Self::empty()
    }
}

impl Default for NativeOwnedBytes {
    fn default() -> Self {
        Self::empty()
    }
}

impl NativeBytes {
    /// Returns an empty borrowed byte view.
    pub const fn empty() -> Self {
        Self {
            ptr: std::ptr::null(),
            len: 0,
        }
    }

    /// Returns `true` when this value represents an empty slice.
    pub const fn is_empty(self) -> bool {
        self.len == 0
    }

    /// Returns `true` when this value has a negative length or a null pointer
    /// with a non-zero length.
    pub const fn is_invalid(self) -> bool {
        self.len < 0 || (self.ptr.is_null() && self.len != 0)
    }
}

impl NativeOwnedBytes {
    /// Returns an empty owned byte handle.
    pub const fn empty() -> Self {
        Self {
            ptr: std::ptr::null_mut(),
            len: 0,
        }
    }

    /// Returns `true` when this value represents no owned bytes.
    pub const fn is_empty(self) -> bool {
        self.len == 0
    }

    /// Returns `true` when this value has a negative length or a null pointer
    /// with a non-zero length.
    pub const fn is_invalid(self) -> bool {
        self.len < 0 || (self.ptr.is_null() && self.len != 0)
    }
}

/// Reads a borrowed native byte view as a Rust byte slice.
///
/// Returns `None` for negative lengths, null pointers with non-zero lengths, or
/// lengths that cannot be represented as `usize`.
///
/// # Safety
///
/// When `value.ptr` is non-null, it must point to `value.len` readable bytes.
pub unsafe fn read_native_bytes<'a>(value: NativeBytes) -> Option<&'a [u8]> {
    if value.len < 0 {
        return None;
    }
    if value.len == 0 {
        return Some(&[]);
    }
    if value.ptr.is_null() {
        return None;
    }

    Some(unsafe { std::slice::from_raw_parts(value.ptr, value.len as usize) })
}

/// Reads a borrowed native byte view as UTF-8.
///
/// # Safety
///
/// Same pointer validity requirements as [`read_native_bytes`].
pub unsafe fn read_native_str<'a>(value: NativeBytes) -> Option<Result<&'a str, Utf8Error>> {
    let bytes = unsafe { read_native_bytes(value) }?;
    Some(std::str::from_utf8(bytes))
}

/// Reads a borrowed native byte view into an owned UTF-8 string.
///
/// Returns `None` for invalid pointers or invalid UTF-8.
///
/// # Safety
///
/// Same pointer validity requirements as [`read_native_bytes`].
pub unsafe fn read_native_string(value: NativeBytes) -> Option<String> {
    unsafe { read_native_str(value) }?
        .ok()
        .map(ToOwned::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::OwnedBytes;

    #[test]
    fn owned_bytes_exposes_native_view() {
        let bytes = OwnedBytes::from("hello");
        let native = bytes.as_native();

        assert_eq!(native.len, 5);
        let read = unsafe { read_native_string(native) };
        assert_eq!(read.as_deref(), Some("hello"));
    }

    #[test]
    fn invalid_native_bytes_are_rejected() {
        let value = NativeBytes {
            ptr: std::ptr::null(),
            len: 1,
        };

        assert!(unsafe { read_native_bytes(value) }.is_none());
        assert!(unsafe { read_native_string(value) }.is_none());
    }
}
