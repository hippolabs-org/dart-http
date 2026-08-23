use crate::bytes::{NativeBytes, NativeOwnedBytes};

/// Rust-owned bytes that can expose a stable [`NativeBytes`] view.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OwnedBytes {
    bytes: Box<[u8]>,
}

impl OwnedBytes {
    /// Creates owned bytes from a vector.
    pub fn from_vec(bytes: Vec<u8>) -> Self {
        Self {
            bytes: bytes.into_boxed_slice(),
        }
    }

    /// Creates owned bytes from a UTF-8 string.
    pub fn from_string(value: String) -> Self {
        Self::from_vec(value.into_bytes())
    }

    /// Returns the byte length.
    pub fn len(&self) -> usize {
        self.bytes.len()
    }

    /// Returns `true` if there are no bytes.
    pub fn is_empty(&self) -> bool {
        self.bytes.is_empty()
    }

    /// Returns the owned bytes as a Rust slice.
    pub fn as_slice(&self) -> &[u8] {
        &self.bytes
    }

    /// Returns a borrowed FFI view of this allocation.
    pub fn as_native(&self) -> NativeBytes {
        NativeBytes {
            ptr: self.bytes.as_ptr(),
            len: self.bytes.len() as isize,
        }
    }
}

impl From<Vec<u8>> for OwnedBytes {
    fn from(bytes: Vec<u8>) -> Self {
        Self::from_vec(bytes)
    }
}

impl From<String> for OwnedBytes {
    fn from(value: String) -> Self {
        Self::from_string(value)
    }
}

impl From<&str> for OwnedBytes {
    fn from(value: &str) -> Self {
        Self::from_vec(value.as_bytes().to_vec())
    }
}

/// Transfers a Rust byte vector to the FFI caller.
///
/// The returned handle must be passed to [`free_owned_bytes`] exactly once.
pub fn into_native_owned_bytes(bytes: Vec<u8>) -> NativeOwnedBytes {
    if bytes.is_empty() {
        return NativeOwnedBytes::empty();
    }

    let mut boxed_bytes = bytes.into_boxed_slice();
    let native_bytes = NativeOwnedBytes {
        ptr: boxed_bytes.as_mut_ptr(),
        len: boxed_bytes.len() as isize,
    };
    std::mem::forget(boxed_bytes);
    native_bytes
}

/// Frees bytes created by [`into_native_owned_bytes`].
///
/// # Safety
///
/// `value` must come from [`into_native_owned_bytes`] or an equivalent boxed
/// byte-slice allocation with the same pointer and length. Passing any other
/// pointer, passing the same value twice, or passing a value with an incorrect
/// length is undefined behavior.
pub unsafe fn free_owned_bytes(value: NativeOwnedBytes) {
    if value.ptr.is_null() || value.len <= 0 {
        return;
    }

    let slice = std::ptr::slice_from_raw_parts_mut(value.ptr, value.len as usize);
    unsafe {
        let _ = Box::<[u8]>::from_raw(slice);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn owned_bytes_can_be_freed() {
        let value = into_native_owned_bytes(vec![1, 2, 3]);

        assert!(!value.ptr.is_null());
        assert_eq!(value.len, 3);
        unsafe { free_owned_bytes(value) };
    }
}
