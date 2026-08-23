use crate::bytes::{NativeBytes, read_native_str, read_native_string};

/// Borrowed UTF-8 string view passed across the Dart FFI boundary.
///
/// This is layout-compatible with [`NativeBytes`] but communicates that the
/// pointed-to bytes are expected to be valid UTF-8.
#[repr(transparent)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct NativeString {
    bytes: NativeBytes,
}

impl Default for NativeString {
    fn default() -> Self {
        Self::empty()
    }
}

impl NativeString {
    /// Returns an empty borrowed string view.
    pub const fn empty() -> Self {
        Self {
            bytes: NativeBytes::empty(),
        }
    }

    /// Wraps a native byte view that is expected to contain UTF-8.
    pub const fn from_bytes(bytes: NativeBytes) -> Self {
        Self { bytes }
    }

    /// Returns the underlying native byte view.
    pub const fn as_bytes(self) -> NativeBytes {
        self.bytes
    }

    /// Returns `true` when this value represents an empty string.
    pub const fn is_empty(self) -> bool {
        self.bytes.is_empty()
    }

    /// Returns `true` when the underlying byte view is invalid.
    pub const fn is_invalid(self) -> bool {
        self.bytes.is_invalid()
    }
}

/// Reads a borrowed native string view as UTF-8.
///
/// # Safety
///
/// Same pointer validity requirements as [`crate::read_native_bytes`].
pub unsafe fn read_native_string_ref<'a>(
    value: NativeString,
) -> Option<Result<&'a str, std::str::Utf8Error>> {
    unsafe { read_native_str(value.as_bytes()) }
}

/// Reads a borrowed native string view into an owned Rust string.
///
/// # Safety
///
/// Same pointer validity requirements as [`crate::read_native_bytes`].
pub unsafe fn read_native_string_owned(value: NativeString) -> Option<String> {
    unsafe { read_native_string(value.as_bytes()) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::OwnedBytes;

    #[test]
    fn native_string_reads_utf8() {
        let owned = OwnedBytes::from("hello");
        let native = NativeString::from_bytes(owned.as_native());

        assert_eq!(
            unsafe { read_native_string_owned(native) }.as_deref(),
            Some("hello"),
        );
    }
}
