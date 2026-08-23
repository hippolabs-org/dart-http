use crate::bytes::NativeBytes;

/// Shared native operation status.
#[repr(i32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NativeStatus {
    /// Operation completed successfully.
    Ok = 0,
    /// Operation failed and error fields should be inspected.
    Error = 1,
}

/// Shared borrowed result envelope for native APIs.
///
/// This type is intended for future C ABI surfaces that need to return a
/// stable status plus optional UTF-8 error code and message bytes.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct NativeResult {
    /// Operation status.
    pub status: NativeStatus,
    /// Stable machine-readable error code, empty on success.
    pub code: NativeBytes,
    /// Human-readable diagnostic message, empty on success.
    pub message: NativeBytes,
}

impl NativeResult {
    /// Returns a success result.
    pub const fn ok() -> Self {
        Self {
            status: NativeStatus::Ok,
            code: NativeBytes::empty(),
            message: NativeBytes::empty(),
        }
    }

    /// Returns an error result with borrowed code and message bytes.
    pub const fn error(code: NativeBytes, message: NativeBytes) -> Self {
        Self {
            status: NativeStatus::Error,
            code,
            message,
        }
    }

    /// Returns `true` when the status is [`NativeStatus::Ok`].
    pub const fn is_ok(self) -> bool {
        matches!(self.status, NativeStatus::Ok)
    }

    /// Returns `true` when the status is [`NativeStatus::Error`].
    pub const fn is_error(self) -> bool {
        matches!(self.status, NativeStatus::Error)
    }
}

impl Default for NativeResult {
    fn default() -> Self {
        Self::ok()
    }
}
