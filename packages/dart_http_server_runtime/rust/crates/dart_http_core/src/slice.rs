/// Borrowed typed slice passed across the Dart FFI boundary.
///
/// The struct is generic for Rust ergonomics, but each concrete use across a C
/// ABI should be mirrored by a concrete typedef or header declaration.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct NativeSlice<T> {
    /// Pointer to the first element, or null for an empty slice.
    pub ptr: *const T,
    /// Number of elements. Negative lengths are treated as invalid by readers.
    pub len: isize,
}

impl<T> Default for NativeSlice<T> {
    fn default() -> Self {
        Self::empty()
    }
}

impl<T> NativeSlice<T> {
    /// Returns an empty borrowed slice view.
    pub const fn empty() -> Self {
        Self {
            ptr: std::ptr::null(),
            len: 0,
        }
    }

    /// Creates a borrowed native slice from a Rust slice.
    pub fn from_slice(value: &[T]) -> Self {
        if value.is_empty() {
            return Self::empty();
        }
        Self {
            ptr: value.as_ptr(),
            len: value.len() as isize,
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

/// Reads a borrowed native slice as a Rust slice.
///
/// # Safety
///
/// When `value.ptr` is non-null, it must point to `value.len` initialized
/// elements that remain valid for the returned lifetime.
pub unsafe fn read_native_slice<'a, T>(value: NativeSlice<T>) -> Option<&'a [T]> {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_slice_reads_values() {
        let values = [1, 2, 3];
        let native = NativeSlice::from_slice(&values);

        assert_eq!(
            unsafe { read_native_slice(native) },
            Some(values.as_slice())
        );
    }
}
