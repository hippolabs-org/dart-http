use std::ffi::{CStr, c_char, c_int, c_void};
use std::sync::OnceLock;

/// Dart native port identifier.
pub type DartNativePort = i64;

/// Reusable Dart completion notifier for native worker pools.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct NativeCompletionPort {
    port: DartNativePort,
}

impl NativeCompletionPort {
    /// Creates a completion notifier from a Dart `SendPort.nativePort` value.
    pub const fn new(port: DartNativePort) -> Self {
        Self { port }
    }

    /// Returns `true` when this notifier does not target a Dart port.
    pub const fn is_empty(self) -> bool {
        self.port == 0
    }

    /// Posts a completed job id to the Dart port.
    ///
    /// Returns `false` when the Dart DL API is not initialized, the port is
    /// empty, or the Dart VM rejects the message.
    pub fn post_job_id(self, job_id: i64) -> bool {
        if self.is_empty() {
            return false;
        }
        let Some(api) = DART_API.get() else {
            return false;
        };
        unsafe { (api.post_integer)(self.port, job_id) }
    }
}

/// Initializes the Dart native API function table.
///
/// The pointer must be `NativeApi.initializeApiDLData` from Dart. Calling this
/// multiple times with the same process API table is harmless.
///
/// # Safety
///
/// `data` must be the valid Dart DL API data pointer for the current process.
pub unsafe fn initialize_dart_api_dl(data: *mut c_void) -> Result<(), String> {
    if data.is_null() {
        return Err("Missing Dart API DL data.".to_string());
    }

    let api = unsafe { DartApi::from_initialize_data(data)? };
    if DART_API.get().is_some() {
        return Ok(());
    }

    DART_API
        .set(api)
        .map_err(|_| "Dart API DL initialization raced.".to_string())
}

#[derive(Clone, Debug)]
struct DartApi {
    post_integer: unsafe extern "C" fn(DartNativePort, i64) -> bool,
}

unsafe impl Send for DartApi {}
unsafe impl Sync for DartApi {}

static DART_API: OnceLock<DartApi> = OnceLock::new();

#[repr(C)]
struct ApiEntry {
    name: *const c_char,
    function: *const c_void,
}

#[repr(C)]
struct Api {
    major: c_int,
    minor: c_int,
    functions: *const ApiEntry,
}

impl DartApi {
    unsafe fn from_initialize_data(data: *mut c_void) -> Result<Self, String> {
        let api = unsafe { &*(data as *const Api) };
        if api.major != 2 {
            return Err(format!(
                "Unsupported Dart API DL version {}.{}.",
                api.major, api.minor
            ));
        }

        let post_integer = unsafe { api.lookup_fn("Dart_PostInteger")? };
        Ok(Self {
            post_integer: unsafe { std::mem::transmute::<_, _>(post_integer) },
        })
    }
}

impl Api {
    unsafe fn lookup_fn(&self, name: &str) -> Result<*const c_void, String> {
        for index in 0..usize::MAX {
            let entry = unsafe { self.functions.add(index) };
            let entry = unsafe { &*entry };
            if entry.name.is_null() {
                break;
            }
            let fn_name = unsafe { CStr::from_ptr(entry.name) };
            if name == fn_name.to_string_lossy() {
                return Ok(entry.function);
            }
        }
        Err(format!("Dart API DL function {name} not found."))
    }
}
