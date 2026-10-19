use super::bytes::NativeBytes;

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
