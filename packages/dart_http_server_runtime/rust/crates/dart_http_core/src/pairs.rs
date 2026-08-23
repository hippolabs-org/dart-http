use std::collections::HashMap;

use crate::bytes::{NativeBytes, read_native_string};
use crate::owned::OwnedBytes;

/// Borrowed UTF-8 key/value pair represented as byte views.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct NativePair {
    /// UTF-8 key bytes.
    pub key: NativeBytes,
    /// UTF-8 value bytes.
    pub value: NativeBytes,
}

/// Rust-owned key/value pair that can expose a stable [`NativePair`] view.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OwnedPair {
    key: OwnedBytes,
    value: OwnedBytes,
}

impl OwnedPair {
    /// Creates a UTF-8 key/value pair.
    pub fn new(key: String, value: String) -> Self {
        Self {
            key: OwnedBytes::from_string(key),
            value: OwnedBytes::from_string(value),
        }
    }

    /// Returns the key bytes.
    pub fn key(&self) -> &OwnedBytes {
        &self.key
    }

    /// Returns the value bytes.
    pub fn value(&self) -> &OwnedBytes {
        &self.value
    }

    /// Returns a borrowed FFI view of this pair.
    pub fn as_native(&self) -> NativePair {
        NativePair {
            key: self.key.as_native(),
            value: self.value.as_native(),
        }
    }
}

impl From<(String, String)> for OwnedPair {
    fn from((key, value): (String, String)) -> Self {
        Self::new(key, value)
    }
}

/// Converts a map into owned UTF-8 pairs.
pub fn owned_pairs_from_map(values: HashMap<String, String>) -> Vec<OwnedPair> {
    values.into_iter().map(OwnedPair::from).collect()
}

/// Converts owned pairs into a boxed native pair array.
///
/// The returned `NativePair` values borrow from `values`; keep `values` alive
/// while the boxed native array is used by Dart.
pub fn native_pairs_from_owned(values: &[OwnedPair]) -> Box<[NativePair]> {
    values
        .iter()
        .map(OwnedPair::as_native)
        .collect::<Vec<_>>()
        .into_boxed_slice()
}

/// Returns the pointer to a boxed native pair array, or null for an empty array.
pub fn boxed_pairs_ptr(values: &[NativePair]) -> *const NativePair {
    if values.is_empty() {
        std::ptr::null()
    } else {
        values.as_ptr()
    }
}

/// Reads a native pair array into an owned vector.
///
/// Pairs with invalid UTF-8 keys or values are skipped.
///
/// # Safety
///
/// `values` must either be null with `count <= 0` or point to `count`
/// consecutive [`NativePair`] values whose embedded byte pointers follow the
/// requirements of [`read_native_string`].
pub unsafe fn read_pairs_vec(values: *const NativePair, count: isize) -> Vec<(String, String)> {
    if count <= 0 || values.is_null() {
        return Vec::new();
    }

    let mut result = Vec::with_capacity(count as usize);
    for index in 0..count {
        let pair = unsafe { values.add(index as usize).read() };
        let Some(key) = (unsafe { read_native_string(pair.key) }) else {
            continue;
        };
        let Some(value) = (unsafe { read_native_string(pair.value) }) else {
            continue;
        };
        result.push((key, value));
    }
    result
}

/// Reads a native pair array into an owned map.
///
/// Duplicate keys keep the last value encountered.
///
/// # Safety
///
/// Same requirements as [`read_pairs_vec`].
pub unsafe fn read_pairs_map(values: *const NativePair, count: isize) -> HashMap<String, String> {
    let mut result = HashMap::with_capacity(count.max(0) as usize);
    for (key, value) in unsafe { read_pairs_vec(values, count) } {
        result.insert(key, value);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_pair_round_trip_preserves_values() {
        let pairs = vec![OwnedPair::new("x".to_string(), "1".to_string())];
        let native_pairs = native_pairs_from_owned(&pairs);

        let read = unsafe { read_pairs_vec(native_pairs.as_ptr(), native_pairs.len() as isize) };

        assert_eq!(read, vec![("x".to_string(), "1".to_string())]);
    }
}
