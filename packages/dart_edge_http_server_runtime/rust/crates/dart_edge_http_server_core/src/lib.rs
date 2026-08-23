//! Shared native HTTP handler ABI types for Dart Edge native crates.

#![deny(missing_docs)]

use std::ffi::c_char;

pub use dart_edge_core::{NativeBytes, NativePair};
use serde::{Deserialize, Serialize};

/// Native ABI method code for `GET`.
pub const NATIVE_HTTP_METHOD_GET: i32 = NativeHttpMethod::Get as i32;
/// Native ABI method code for `POST`.
pub const NATIVE_HTTP_METHOD_POST: i32 = NativeHttpMethod::Post as i32;
/// Native ABI method code for `PUT`.
pub const NATIVE_HTTP_METHOD_PUT: i32 = NativeHttpMethod::Put as i32;
/// Native ABI method code for `PATCH`.
pub const NATIVE_HTTP_METHOD_PATCH: i32 = NativeHttpMethod::Patch as i32;
/// Native ABI method code for `DELETE`.
pub const NATIVE_HTTP_METHOD_DELETE: i32 = NativeHttpMethod::Delete as i32;
/// Native ABI method code for `HEAD`.
pub const NATIVE_HTTP_METHOD_HEAD: i32 = NativeHttpMethod::Head as i32;
/// Native ABI method code for `OPTIONS`.
pub const NATIVE_HTTP_METHOD_OPTIONS: i32 = NativeHttpMethod::Options as i32;

/// Native HTTP method code shared across Dart Edge native crates.
#[repr(i32)]
#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum NativeHttpMethod {
    /// GET.
    Get = 0,
    /// POST.
    Post = 1,
    /// PUT.
    Put = 2,
    /// PATCH.
    Patch = 3,
    /// DELETE.
    Delete = 4,
    /// HEAD.
    Head = 5,
    /// OPTIONS.
    Options = 6,
}

impl NativeHttpMethod {
    /// Returns the native ABI method code.
    pub const fn code(self) -> i32 {
        self as i32
    }

    /// Decodes a native ABI method code.
    pub const fn from_code(value: i32) -> Option<Self> {
        match value {
            0 => Some(Self::Get),
            1 => Some(Self::Post),
            2 => Some(Self::Put),
            3 => Some(Self::Patch),
            4 => Some(Self::Delete),
            5 => Some(Self::Head),
            6 => Some(Self::Options),
            _ => None,
        }
    }

    /// Returns the uppercase HTTP method name.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Get => "GET",
            Self::Post => "POST",
            Self::Put => "PUT",
            Self::Patch => "PATCH",
            Self::Delete => "DELETE",
            Self::Head => "HEAD",
            Self::Options => "OPTIONS",
        }
    }

    /// Decodes an uppercase HTTP method name.
    pub fn from_name(value: &str) -> Option<Self> {
        match value {
            "GET" => Some(Self::Get),
            "POST" => Some(Self::Post),
            "PUT" => Some(Self::Put),
            "PATCH" => Some(Self::Patch),
            "DELETE" => Some(Self::Delete),
            "HEAD" => Some(Self::Head),
            "OPTIONS" => Some(Self::Options),
            _ => None,
        }
    }

    /// Decodes an OpenAPI lowercase HTTP method name.
    pub fn from_openapi_name(value: &str) -> Option<Self> {
        match value {
            "get" => Some(Self::Get),
            "post" => Some(Self::Post),
            "put" => Some(Self::Put),
            "patch" => Some(Self::Patch),
            "delete" => Some(Self::Delete),
            "head" => Some(Self::Head),
            "options" => Some(Self::Options),
            _ => None,
        }
    }
}

/// Native HTTP route descriptor serialized into Dart route manifests.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeHttpRoute {
    /// HTTP method name.
    pub method: NativeHttpMethod,
    /// Absolute route path.
    pub path: String,
    /// Stable operation id.
    pub operation_id: String,
    /// Whether the route accepts a JSON body.
    pub accepts_json_body: bool,
    /// Plugin or native module that contributed this route.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plugin_name: Option<String>,
}

impl NativeHttpRoute {
    /// Creates a native HTTP route descriptor.
    pub fn new(
        method: NativeHttpMethod,
        path: String,
        operation_id: impl Into<String>,
        accepts_json_body: bool,
        plugin_name: Option<String>,
    ) -> Self {
        Self {
            method,
            path,
            operation_id: operation_id.into(),
            accepts_json_body,
            plugin_name,
        }
    }
}

/// Manifest wrapper for native HTTP route descriptors.
#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeHttpRouteManifest {
    /// Native HTTP routes exposed by the package.
    pub routes: Vec<NativeHttpRoute>,
}

impl NativeHttpRouteManifest {
    /// Creates a native HTTP route manifest.
    pub fn new(routes: Vec<NativeHttpRoute>) -> Self {
        Self { routes }
    }

    /// Encodes the manifest as JSON.
    pub fn to_json(&self) -> serde_json::Result<String> {
        serde_json::to_string(self)
    }

    /// Decodes the manifest from JSON.
    pub fn from_json(value: &str) -> serde_json::Result<Self> {
        serde_json::from_str(value)
    }
}

/// Encodes a native HTTP route list as JSON.
pub fn native_http_routes_to_json(routes: &[NativeHttpRoute]) -> serde_json::Result<String> {
    serde_json::to_string(routes)
}

/// Decodes a native HTTP route list from JSON.
pub fn native_http_routes_from_json(value: &str) -> serde_json::Result<Vec<NativeHttpRoute>> {
    serde_json::from_str(value)
}

/// Shared serializable error shape for native HTTP helper APIs.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeHttpError {
    /// Stable machine-readable error code.
    pub code: String,
    /// Human-readable error message.
    pub message: String,
}

impl NativeHttpError {
    /// Creates a native HTTP error value.
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    /// Encodes the error as JSON.
    pub fn to_json(&self) -> serde_json::Result<String> {
        serde_json::to_string(self)
    }
}

/// Shared result alias for native HTTP helper APIs.
pub type NativeHttpResult<T> = Result<T, NativeHttpError>;

/// Native HTTP request passed to a native route handler.
#[repr(C)]
pub struct NativeHttpRequest {
    /// HTTP method code.
    pub method: i32,
    /// Full request path.
    pub path: *const c_char,
    /// Number of query pairs.
    pub query_count: isize,
    /// Borrowed query pairs.
    pub query: *const NativePair,
    /// Number of header pairs.
    pub header_count: isize,
    /// Borrowed header pairs.
    pub headers: *const NativePair,
    /// Borrowed request body bytes.
    pub body: NativeBytes,
}

/// Native HTTP response returned by a native route handler.
#[repr(C)]
pub struct NativeHttpResponse {
    /// HTTP response status code.
    pub status: u16,
    /// Response content type bytes.
    pub content_type: NativeBytes,
    /// Number of header pairs.
    pub header_count: isize,
    /// Borrowed response header pairs.
    pub headers: *const NativePair,
    /// Response body bytes.
    pub body: NativeBytes,
}

/// Native HTTP route handler function pointer.
pub type NativeHttpHandler =
    unsafe extern "C" fn(handle: i64, request: *const NativeHttpRequest) -> *mut NativeHttpResponse;

/// Function pointer used to release a response returned by [`NativeHttpHandler`].
pub type NativeHttpFreeResponse = unsafe extern "C" fn(value: *mut NativeHttpResponse);
