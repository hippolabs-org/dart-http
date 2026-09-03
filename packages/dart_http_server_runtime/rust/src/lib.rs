// Exported C ABI functions validate pointer inputs at the boundary while
// remaining safe to call from generated Dart FFI bindings.
#![allow(clippy::not_unsafe_ptr_arg_deref)]
// Session handlers intentionally keep their protocol state explicit.
#![allow(clippy::too_many_arguments)]
// Axum responses are returned directly to keep the request path allocation-free.
#![allow(clippy::result_large_err)]

use std::collections::{HashMap, VecDeque};
use std::ffi::{CStr, CString, c_char};
use std::net::{IpAddr, SocketAddr};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::mpsc as std_mpsc;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use axum::Router;
use axum::body::{Body, Bytes};
use axum::extract::Request;
use axum::extract::ws::{CloseFrame, Message, WebSocket, WebSocketUpgrade, close_code};
use axum::extract::{FromRequestParts, State};
use axum::http::{HeaderMap, HeaderName, HeaderValue, Method, Response, StatusCode, header};
use axum::middleware::{self, Next};
use axum::response::IntoResponse;
use axum::routing::any;
use dart_http_core::{
    NativeBytes, NativePair, OwnedBytes, OwnedPair, boxed_pairs_ptr, native_pairs_from_owned,
    owned_pairs_from_map, read_native_bytes, read_native_string, read_pairs_vec,
};
use dart_http_server_core::{
    NativeHttpFreeResponse, NativeHttpHandler, NativeHttpMethod, NativeHttpRequest,
};
use futures_util::StreamExt;
use native_exchange_rust::abi::{
    NEX_ABI_VERSION, NEX_CAPABILITY_CONCURRENT_CANCEL, NEX_CAPABILITY_THREAD_SAFE,
    NEX_STREAM_READ_CHUNK, NEX_STREAM_READ_DONE, NEX_STREAM_READ_ERROR, NexBuffer, NexByteStream,
    NexUtf8View,
};
use native_exchange_rust::{AdoptedByteStream, StreamCancelHandle, StreamRead};
use once_cell::sync::Lazy;
use serde::Deserialize;
use serde_json::Value;
use tokio::net::TcpListener;
use tokio::sync::{mpsc, watch};
use tower_http::cors::{Any, CorsLayer};
use wtransport::{
    Connection as WebTransportConnection, Endpoint as WebTransportEndpoint, Identity,
    ServerConfig as WebTransportServerConfig, VarInt,
};

const DART_HTTP_SERVER_RUNTIME_NATIVE_ABI_VERSION: i32 = 18;
const SCHEMA_REGISTRY_URI: &str = "urn:dart-http:schema-registry";
const DEFAULT_REALTIME_MAX_PENDING_MESSAGES: usize = 256;
const DEFAULT_REALTIME_MAX_PENDING_BYTES: usize = 8 * 1024 * 1024;
const REALTIME_OVERLOAD_CODE: u32 = 0x100;

type TransportEventCallback = extern "C" fn(i32, i64);

static NEXT_REQUEST_ID: AtomicI64 = AtomicI64::new(1);
static NEXT_SERVER_ID: AtomicI64 = AtomicI64::new(1);
static NEXT_WEB_SOCKET_SESSION_ID: AtomicI64 = AtomicI64::new(1);
static NEXT_WEB_TRANSPORT_SESSION_ID: AtomicI64 = AtomicI64::new(1);
static NEXT_WEB_TRANSPORT_STREAM_HANDLE_ID: AtomicI64 = AtomicI64::new(1);
static NEXT_WEB_TRANSPORT_OPERATION_ID: AtomicI64 = AtomicI64::new(1);
static LAST_ERROR: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));
static PENDING_REQUESTS: Lazy<Mutex<HashMap<i64, PendingRequest>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static WEB_SOCKET_SESSIONS: Lazy<Mutex<HashMap<i64, WebSocketSessionState>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static WEB_TRANSPORT_SESSIONS: Lazy<Mutex<HashMap<i64, WebTransportSessionState>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static WEB_TRANSPORT_STREAMS: Lazy<Mutex<HashMap<i64, WebTransportStreamState>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static WEB_TRANSPORT_OPENED_STREAMS: Lazy<Mutex<HashMap<i64, WebTransportStreamInfo>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static WEB_TRANSPORT_OPERATIONS: Lazy<Mutex<HashMap<i64, WebTransportOperationResult>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static SERVER_STATES: Lazy<Mutex<HashMap<i64, ServerState>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

struct PendingRequest {
    server_id: i64,
    request: Option<TransportRequest>,
    response_tx: mpsc::UnboundedSender<PendingResponseMessage>,
}

struct ServerState {
    shutdown_tx: Option<watch::Sender<bool>>,
    join_handle: Option<thread::JoinHandle<()>>,
}

#[derive(Clone)]
struct ServerRuntimeState {
    server_id: i64,
    routes: Arc<Vec<CompiledRoute>>,
    schemas: Arc<HashMap<String, jsonschema::Validator>>,
    callback: TransportEventCallback,
}

#[repr(C)]
pub struct NativeTransportRequest {
    route_id: NativeBytes,
    path_param_count: isize,
    path_params: *const NativePair,
    query_count: isize,
    query: *const NativePair,
    header_count: isize,
    headers: *const NativePair,
    body: NativeBytes,
    request_kind: u8,
    body_kind: u8,
}

#[repr(C)]
pub struct NativeMultipartField {
    name: NativeBytes,
    value: NativeBytes,
}

#[repr(C)]
pub struct NativeMultipartFile {
    field_name: NativeBytes,
    filename: NativeBytes,
    content_type: NativeBytes,
    body: NativeBytes,
}

#[repr(C)]
pub struct NativeMultipartForm {
    field_count: isize,
    fields: *const NativeMultipartField,
    file_count: isize,
    files: *const NativeMultipartFile,
}

#[repr(C)]
pub struct NativeWebSocketConnection {
    session_id: i64,
    request_id: i64,
    route_id: NativeBytes,
    path_param_count: isize,
    path_params: *const NativePair,
    query_count: isize,
    query: *const NativePair,
    header_count: isize,
    headers: *const NativePair,
}

#[repr(C)]
pub struct NativeWebSocketMessage {
    session_id: i64,
    kind: u8,
    body: NativeBytes,
}

#[repr(C)]
pub struct NativeWebTransportConnection {
    session_id: i64,
    request_id: i64,
    route_id: NativeBytes,
    path_param_count: isize,
    path_params: *const NativePair,
    query_count: isize,
    query: *const NativePair,
    header_count: isize,
    headers: *const NativePair,
}

#[repr(C)]
pub struct NativeWebTransportDatagram {
    session_id: i64,
    body: NativeBytes,
}

#[repr(C)]
pub struct NativeWebTransportStream {
    session_id: i64,
    body: NativeBytes,
}

#[repr(C)]
pub struct NativeWebTransportStreamInfo {
    session_id: i64,
    stream_id: i64,
    protocol_id: i64,
    kind: u8,
}

#[repr(C)]
pub struct NativeWebTransportStreamChunk {
    stream_id: i64,
    body: NativeBytes,
}

#[repr(C)]
pub struct NativeWebTransportStreamTerminal {
    stream_id: i64,
    error_code: i64,
    error: NativeBytes,
}

#[repr(C)]
pub struct NativeWebTransportOperation {
    operation_id: i64,
    session_id: i64,
    stream_id: i64,
    protocol_id: i64,
    kind: u8,
    succeeded: bool,
    error: NativeBytes,
}

#[repr(C)]
struct NativeTransportRequestHandle {
    request: NativeTransportRequest,
    route_id: OwnedBytes,
    path_params: Vec<OwnedPair>,
    path_param_pairs: Box<[NativePair]>,
    query: Vec<OwnedPair>,
    query_pairs: Box<[NativePair]>,
    headers: Vec<OwnedPair>,
    header_pairs: Box<[NativePair]>,
    body: Option<OwnedBytes>,
    body_stream: Option<ProducedIncomingBodyStream>,
}

#[repr(C)]
struct NativeMultipartFormHandle {
    form: NativeMultipartForm,
    fields: Vec<OwnedMultipartField>,
    field_storage: Box<[NativeMultipartField]>,
    files: Vec<OwnedMultipartFile>,
    file_storage: Box<[NativeMultipartFile]>,
}

#[repr(C)]
struct NativeWebSocketConnectionHandle {
    connection: NativeWebSocketConnection,
    route_id: OwnedBytes,
    path_params: Vec<OwnedPair>,
    path_param_pairs: Box<[NativePair]>,
    query: Vec<OwnedPair>,
    query_pairs: Box<[NativePair]>,
    headers: Vec<OwnedPair>,
    header_pairs: Box<[NativePair]>,
}

#[repr(C)]
struct NativeWebSocketMessageHandle {
    message: NativeWebSocketMessage,
    body: OwnedBytes,
}

#[repr(C)]
struct NativeWebTransportConnectionHandle {
    connection: NativeWebTransportConnection,
    route_id: OwnedBytes,
    path_params: Vec<OwnedPair>,
    path_param_pairs: Box<[NativePair]>,
    query: Vec<OwnedPair>,
    query_pairs: Box<[NativePair]>,
    headers: Vec<OwnedPair>,
    header_pairs: Box<[NativePair]>,
}

#[repr(C)]
struct NativeWebTransportDatagramHandle {
    datagram: NativeWebTransportDatagram,
    body: OwnedBytes,
}

#[repr(C)]
struct NativeWebTransportStreamHandle {
    stream: NativeWebTransportStream,
    body: OwnedBytes,
}

#[repr(C)]
struct NativeWebTransportStreamChunkHandle {
    chunk: NativeWebTransportStreamChunk,
    body: OwnedBytes,
}

#[repr(C)]
struct NativeWebTransportStreamTerminalHandle {
    terminal: NativeWebTransportStreamTerminal,
    error: OwnedBytes,
}

#[repr(C)]
struct NativeWebTransportOperationHandle {
    operation: NativeWebTransportOperation,
    error: OwnedBytes,
}

#[repr(u8)]
#[derive(Clone, Copy)]
enum NativeBodyKind {
    None = 0,
    Text = 1,
    Json = 2,
    Multipart = 3,
}

#[repr(u8)]
#[derive(Clone, Copy)]
enum NativeRequestKind {
    Http = 0,
    WebSocket = 1,
    WebTransport = 2,
}

struct TransportRequest {
    route_id: String,
    path_params: HashMap<String, String>,
    query: HashMap<String, String>,
    headers: HashMap<String, String>,
    body: Option<Vec<u8>>,
    body_stream: Option<ProducedIncomingBodyStream>,
    request_kind: NativeRequestKind,
    body_kind: NativeBodyKind,
}

struct TransportResponse {
    status: u16,
    content_type: String,
    body: Vec<u8>,
    headers: Vec<(String, String)>,
}

enum PendingResponseMessage {
    Http(TransportResponse),
    SseStart {
        status: u16,
        headers: Vec<(String, String)>,
    },
    SseChunk(String),
    BinaryStart {
        status: u16,
        content_type: String,
        content_length: Option<u64>,
        headers: Vec<(String, String)>,
    },
    BinaryChunk {
        bytes: Vec<u8>,
        consumed_tx: std_mpsc::SyncSender<()>,
    },
    NativeBinaryStart {
        status: u16,
        content_type: String,
        content_length: Option<u64>,
        headers: Vec<(String, String)>,
        stream: AdoptedByteStream,
    },
    WebSocketAccept {
        headers: Vec<(String, String)>,
    },
    Close,
}

struct CancelNativeResponseOnDrop(Option<StreamCancelHandle>);

impl Drop for CancelNativeResponseOnDrop {
    fn drop(&mut self) {
        if let Some(cancel) = self.0.take() {
            cancel.cancel();
        }
    }
}

fn run_native_response_worker(
    stream: AdoptedByteStream,
    sender: mpsc::Sender<Result<Bytes, std::io::Error>>,
    content_length: Option<u64>,
) {
    let reader = stream.reader();
    let mut remaining = content_length;
    loop {
        match reader.read_next() {
            Ok(StreamRead::Chunk(buffer)) => {
                let bytes = buffer.into_bytes();
                if let Some(bytes_remaining) = remaining.as_mut() {
                    let chunk_length = bytes.len() as u64;
                    if chunk_length > *bytes_remaining {
                        let _ = sender.blocking_send(Err(std::io::Error::other(format!(
                            "Native response exceeded its declared content length by {} bytes.",
                            chunk_length - *bytes_remaining
                        ))));
                        return;
                    }
                    *bytes_remaining -= chunk_length;
                }
                if !bytes.is_empty() && sender.blocking_send(Ok(bytes)).is_err() {
                    return;
                }
                if remaining == Some(0) {
                    stream.mark_complete();
                    return;
                }
            }
            Ok(StreamRead::Done) => {
                if let Some(bytes_remaining) = remaining
                    && bytes_remaining != 0
                {
                    let _ = sender.blocking_send(Err(std::io::Error::other(format!(
                        "Native response ended with {bytes_remaining} declared bytes remaining."
                    ))));
                }
                return;
            }
            Ok(StreamRead::Canceled) => return,
            Err(error) => {
                let _ = sender.blocking_send(Err(std::io::Error::other(error)));
                return;
            }
        }
    }
}

fn release_rejected_native_stream(stream: NexByteStream) {
    if let Some(cancel) = stream.cancel {
        unsafe { cancel(stream.context) };
    }
    if let Some(release) = stream.release {
        unsafe { release(stream.context) };
    }
}

enum IncomingBodyMessage {
    Chunk(Bytes),
    Done,
    Error(Vec<u8>),
}

struct IncomingBodyStreamContext {
    receiver: Mutex<mpsc::Receiver<IncomingBodyMessage>>,
    cancel_tx: watch::Sender<bool>,
    last_error: Mutex<Vec<u8>>,
}

struct IncomingBodyBuffer {
    bytes: Bytes,
}

struct ProducedIncomingBodyStream {
    descriptor: Option<NexByteStream>,
}

// The descriptor advertises thread-safe callbacks, and every mutable field in
// its context is synchronized. Ownership may therefore cross the request map.
unsafe impl Send for ProducedIncomingBodyStream {}
unsafe impl Sync for ProducedIncomingBodyStream {}

impl ProducedIncomingBodyStream {
    fn from_body(body: Body) -> Self {
        let (sender, receiver) = mpsc::channel(1);
        let (cancel_tx, mut cancel_rx) = watch::channel(false);
        tokio::spawn(async move {
            let mut stream = body.into_data_stream();
            loop {
                tokio::select! {
                    changed = cancel_rx.changed() => {
                        if changed.is_err() || *cancel_rx.borrow() {
                            return;
                        }
                    }
                    next = stream.next() => {
                        let message = match next {
                            Some(Ok(bytes)) => IncomingBodyMessage::Chunk(bytes),
                            Some(Err(error)) => IncomingBodyMessage::Error(error.to_string().into_bytes()),
                            None => IncomingBodyMessage::Done,
                        };
                        let terminal = matches!(message, IncomingBodyMessage::Done | IncomingBodyMessage::Error(_));
                        if sender.send(message).await.is_err() || terminal {
                            return;
                        }
                    }
                }
            }
        });

        let context = Box::new(IncomingBodyStreamContext {
            receiver: Mutex::new(receiver),
            cancel_tx,
            last_error: Mutex::new(Vec::new()),
        });
        Self {
            descriptor: Some(NexByteStream {
                abi_version: NEX_ABI_VERSION,
                struct_size: std::mem::size_of::<NexByteStream>(),
                capabilities: NEX_CAPABILITY_THREAD_SAFE | NEX_CAPABILITY_CONCURRENT_CANCEL,
                context: Box::into_raw(context).cast(),
                next: Some(incoming_body_stream_next),
                cancel: Some(incoming_body_stream_cancel),
                release: Some(incoming_body_stream_release),
            }),
        }
    }

    fn into_descriptor(mut self) -> NexByteStream {
        self.descriptor
            .take()
            .expect("incoming body stream has already been transferred")
    }
}

impl Drop for ProducedIncomingBodyStream {
    fn drop(&mut self) {
        if let Some(descriptor) = self.descriptor.take() {
            release_rejected_native_stream(descriptor);
        }
    }
}

unsafe extern "C" fn incoming_body_stream_next(
    context: *mut std::ffi::c_void,
    out_buffer: *mut NexBuffer,
    out_error: *mut NexUtf8View,
) -> i32 {
    if context.is_null() || out_buffer.is_null() || out_error.is_null() {
        return NEX_STREAM_READ_ERROR;
    }
    let context = unsafe { &*context.cast::<IncomingBodyStreamContext>() };
    let message = context
        .receiver
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .blocking_recv();
    match message {
        Some(IncomingBodyMessage::Chunk(bytes)) => {
            let buffer = Box::new(IncomingBodyBuffer { bytes });
            let ptr = if buffer.bytes.is_empty() {
                std::ptr::null()
            } else {
                buffer.bytes.as_ptr()
            };
            let len = buffer.bytes.len();
            unsafe {
                out_buffer.write(NexBuffer {
                    abi_version: NEX_ABI_VERSION,
                    struct_size: std::mem::size_of::<NexBuffer>(),
                    capabilities: NEX_CAPABILITY_THREAD_SAFE,
                    ptr,
                    len,
                    context: Box::into_raw(buffer).cast(),
                    release: Some(incoming_body_buffer_release),
                });
            }
            NEX_STREAM_READ_CHUNK
        }
        Some(IncomingBodyMessage::Done) | None => NEX_STREAM_READ_DONE,
        Some(IncomingBodyMessage::Error(message)) => {
            let mut error = context
                .last_error
                .lock()
                .unwrap_or_else(|error| error.into_inner());
            *error = message;
            unsafe {
                out_error.write(NexUtf8View {
                    ptr: error.as_ptr(),
                    len: error.len(),
                });
            }
            NEX_STREAM_READ_ERROR
        }
    }
}

unsafe extern "C" fn incoming_body_stream_cancel(context: *mut std::ffi::c_void) {
    if context.is_null() {
        return;
    }
    let context = unsafe { &*context.cast::<IncomingBodyStreamContext>() };
    let _ = context.cancel_tx.send(true);
}

unsafe extern "C" fn incoming_body_stream_release(context: *mut std::ffi::c_void) {
    if !context.is_null() {
        unsafe { drop(Box::from_raw(context.cast::<IncomingBodyStreamContext>())) };
    }
}

unsafe extern "C" fn incoming_body_buffer_release(context: *mut std::ffi::c_void) {
    if !context.is_null() {
        unsafe { drop(Box::from_raw(context.cast::<IncomingBodyBuffer>())) };
    }
}

struct WebSocketSessionState {
    server_id: i64,
    connection: Option<WebSocketConnection>,
    messages: VecDeque<WebSocketIncomingMessage>,
    pending_bytes: usize,
    max_pending_messages: usize,
    max_pending_bytes: usize,
    command_tx: mpsc::UnboundedSender<WebSocketCommand>,
}

struct WebSocketConnection {
    session_id: i64,
    request_id: i64,
    route_id: String,
    path_params: HashMap<String, String>,
    query: HashMap<String, String>,
    headers: HashMap<String, String>,
}

struct WebSocketIncomingMessage {
    session_id: i64,
    kind: WebSocketMessageKind,
    body: Vec<u8>,
}

struct WebTransportSessionState {
    server_id: i64,
    connection: Option<WebTransportConnectionInfo>,
    datagrams: VecDeque<WebTransportIncomingDatagram>,
    streams: VecDeque<WebTransportIncomingStream>,
    pending_bytes: usize,
    max_pending_messages: usize,
    max_pending_bytes: usize,
    command_tx: mpsc::UnboundedSender<WebTransportCommand>,
}

struct WebTransportConnectionInfo {
    session_id: i64,
    request_id: i64,
    route_id: String,
    path_params: HashMap<String, String>,
    query: HashMap<String, String>,
    headers: HashMap<String, String>,
}

struct WebTransportIncomingDatagram {
    session_id: i64,
    body: Vec<u8>,
}

struct WebTransportIncomingStream {
    session_id: i64,
    body: Vec<u8>,
}

#[derive(Clone, Copy)]
struct WebTransportStreamInfo {
    session_id: i64,
    stream_id: i64,
    protocol_id: i64,
    kind: WebTransportStreamKind,
}

struct WebTransportStreamState {
    info: WebTransportStreamInfo,
    runtime_state: ServerRuntimeState,
    chunks: VecDeque<Vec<u8>>,
    pending_bytes: usize,
    max_pending_messages: usize,
    max_pending_bytes: usize,
    terminal: Option<WebTransportStreamTerminal>,
    send_tx: Option<mpsc::Sender<WebTransportStreamCommand>>,
    stop_tx: Option<mpsc::UnboundedSender<u32>>,
    send_closed: bool,
    receive_closed: bool,
}

struct WebTransportStreamTerminal {
    error_code: Option<u32>,
    error: String,
}

struct WebTransportOperationResult {
    operation_id: i64,
    session_id: i64,
    stream_id: i64,
    protocol_id: i64,
    kind: WebTransportOperationKind,
    error: Option<String>,
}

#[repr(u8)]
#[derive(Clone, Copy)]
enum WebTransportStreamKind {
    IncomingUnidirectional = 1,
    IncomingBidirectional = 2,
    OutgoingUnidirectional = 3,
    OutgoingBidirectional = 4,
}

#[repr(u8)]
#[derive(Clone, Copy)]
enum WebTransportOperationKind {
    OpenUnidirectional = 1,
    OpenBidirectional = 2,
    Write = 3,
    Finish = 4,
    Reset = 5,
    Stop = 6,
}

enum WebTransportStreamCommand {
    Write { operation_id: i64, body: Vec<u8> },
    Finish { operation_id: i64 },
    Reset { operation_id: i64, error_code: u32 },
}

#[derive(Clone, Copy)]
enum WebSocketMessageKind {
    Text = 1,
    Binary = 2,
}

enum WebSocketCommand {
    SendText(String),
    SendBinary(Vec<u8>),
    Close {
        code: Option<u16>,
        reason: Option<String>,
    },
}

enum WebTransportCommand {
    SendDatagram(Vec<u8>),
    SendStream(Vec<u8>),
    OpenUnidirectional {
        operation_id: i64,
    },
    OpenBidirectional {
        operation_id: i64,
    },
    Close {
        code: Option<u32>,
        reason: Option<String>,
    },
}

#[derive(Deserialize)]
struct RouteManifest {
    routes: Vec<RouteManifestEntry>,
    #[serde(default)]
    schemas: HashMap<String, serde_json::Value>,
}

#[derive(Clone, Copy, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
enum RouteTransportKind {
    #[default]
    Http,
    NativeHttp,
    WebSocket,
    WebTransport,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RouteManifestEntry {
    #[serde(default)]
    kind: RouteTransportKind,
    route_id: String,
    method: NativeHttpMethod,
    path_segments: Vec<RouteSegmentManifest>,
    handler_path_segments: Option<Vec<RouteSegmentManifest>>,
    params_schema_id: Option<String>,
    query_schema_id: Option<String>,
    headers_schema_id: Option<String>,
    request_body: Option<RequestBodyManifest>,
    native_handle: Option<i64>,
    native_handler_address: Option<usize>,
    native_free_response_address: Option<usize>,
    #[serde(default = "default_realtime_max_pending_messages")]
    max_pending_messages: usize,
    #[serde(default = "default_realtime_max_pending_bytes")]
    max_pending_bytes: usize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RouteSegmentManifest {
    value: String,
    is_parameter: bool,
    #[serde(default)]
    is_wildcard: bool,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RequestBodyManifest {
    content_type: String,
    schema_id: Option<String>,
    #[serde(default)]
    streaming: bool,
}

#[derive(Clone)]
struct CompiledRoute {
    kind: RouteTransportKind,
    route_id: String,
    method: NativeHttpMethod,
    path_segments: Vec<CompiledRouteSegment>,
    params_schema_id: Option<String>,
    query_schema_id: Option<String>,
    headers_schema_id: Option<String>,
    request_body: Option<RequestBodyValidation>,
    native_handler: Option<CompiledNativeHttpHandler>,
    max_pending_messages: usize,
    max_pending_bytes: usize,
}

#[derive(Clone)]
struct CompiledNativeHttpHandler {
    handle: i64,
    handler: NativeHttpHandler,
    free_response: NativeHttpFreeResponse,
    handler_path_segments: Option<Vec<CompiledRouteSegment>>,
}

#[derive(Clone)]
enum CompiledRouteSegment {
    Literal(String),
    Parameter(String),
    Wildcard(String),
}

#[derive(Clone)]
struct RequestBodyValidation {
    content_type: String,
    kind: RequestBodyKind,
    schema_id: Option<String>,
    streaming: bool,
}

#[derive(Clone, Copy)]
enum RequestBodyKind {
    Json,
    Text,
    Multipart,
    Other,
}

#[derive(Clone)]
struct NativeRouteMatch {
    kind: RouteTransportKind,
    route_id: String,
    path_params: HashMap<String, String>,
    params_schema_id: Option<String>,
    query_schema_id: Option<String>,
    headers_schema_id: Option<String>,
    request_body: Option<RequestBodyValidation>,
    native_handler: Option<CompiledNativeHttpHandler>,
    max_pending_messages: usize,
    max_pending_bytes: usize,
}

#[derive(Clone)]
struct ValidatedRouteRequest {
    route_match: NativeRouteMatch,
    method: String,
    path: String,
    query: HashMap<String, String>,
    headers: HashMap<String, String>,
    body: Option<ValidatedBody>,
    runtime_state: ServerRuntimeState,
}

#[derive(Clone)]
struct ValidatedBody {
    bytes: Option<Vec<u8>>,
    kind: NativeBodyKind,
    json: Option<serde_json::Value>,
}

struct ParsedMultipartForm {
    fields: Vec<ParsedMultipartField>,
    files: Vec<ParsedMultipartFile>,
}

struct ParsedMultipartField {
    name: String,
    value: String,
}

struct ParsedMultipartFile {
    field_name: String,
    filename: Option<String>,
    content_type: Option<String>,
    body_start: usize,
    body_len: usize,
}

struct ParsedContentDisposition {
    name: String,
    filename: Option<String>,
}

struct OwnedMultipartField {
    name: OwnedBytes,
    value: OwnedBytes,
}

struct OwnedMultipartFile {
    field_name: OwnedBytes,
    filename: Option<OwnedBytes>,
    content_type: Option<OwnedBytes>,
    body: NativeBytes,
}

struct CompiledManifest {
    routes: Vec<CompiledRoute>,
    schemas: HashMap<String, jsonschema::Validator>,
}

#[derive(Deserialize)]
struct MiddlewareManifest {
    #[serde(default)]
    middlewares: Vec<MiddlewareManifestEntry>,
}

#[derive(Deserialize)]
struct MiddlewareManifestEntry {
    name: String,
    #[serde(default)]
    configuration: serde_json::Value,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CorsMiddlewareConfiguration {
    #[serde(default)]
    allow_origins: Vec<String>,
    #[serde(default)]
    allow_headers: Vec<String>,
}

#[repr(i32)]
#[derive(Clone, Copy)]
enum TransportEventKind {
    RequestReady = 1,
    WebSocketOpened = 2,
    WebSocketMessageReady = 3,
    WebSocketClosed = 4,
    WebTransportOpened = 5,
    WebTransportDatagramReady = 6,
    WebTransportClosed = 7,
    WebTransportStreamReady = 8,
    WebTransportPersistentStreamOpened = 9,
    WebTransportStreamChunkReady = 10,
    WebTransportStreamFinished = 11,
    WebTransportOperationReady = 12,
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_native_abi_version() -> i32 {
    DART_HTTP_SERVER_RUNTIME_NATIVE_ABI_VERSION
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_start_server(
    host: *const c_char,
    port: i64,
    worker_count: i64,
    routes_json: *const c_char,
    middlewares_json: *const c_char,
    callback: TransportEventCallback,
) -> i64 {
    let Some(host) = (unsafe { read_c_string(host) }) else {
        return -1;
    };
    let Some(routes_json) = (unsafe { read_c_string(routes_json) }) else {
        return -1;
    };
    let Some(middlewares_json) = (unsafe { read_c_string(middlewares_json) }) else {
        return -1;
    };

    let compiled_manifest = match compile_manifest(&routes_json) {
        Ok(manifest) => manifest,
        Err(error) => {
            eprintln!("dart_http_server_runtime route manifest parse failed: {error}");
            return -1;
        }
    };
    let cors_layer = match compile_cors_layer(&middlewares_json) {
        Ok(layer) => layer,
        Err(error) => {
            eprintln!("dart_http_server_runtime middleware manifest parse failed: {error}");
            return -1;
        }
    };

    let server_id = NEXT_SERVER_ID.fetch_add(1, Ordering::Relaxed);
    let runtime_state = ServerRuntimeState {
        server_id,
        routes: Arc::new(compiled_manifest.routes),
        schemas: Arc::new(compiled_manifest.schemas),
        callback,
    };

    let (ready_tx, ready_rx) = std::sync::mpsc::channel();
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let bind_host = host;
    let requested_port = port as u16;
    let worker_count = worker_count.max(1) as usize;

    let join_handle = thread::spawn(move || {
        let runtime = match build_runtime(worker_count) {
            Ok(runtime) => runtime,
            Err(error) => {
                let _ = ready_tx.send(Err(error.to_string()));
                return;
            }
        };

        runtime.block_on(async move {
            let bind_address = match resolve_bind_address(&bind_host, requested_port) {
                Ok(address) => address,
                Err(error) => {
                    let _ = ready_tx.send(Err(error));
                    return;
                }
            };
            let listener = match TcpListener::bind(bind_address).await {
                Ok(listener) => listener,
                Err(error) => {
                    let _ = ready_tx.send(Err(error.to_string()));
                    return;
                }
            };

            let local_port = match listener.local_addr() {
                Ok(address) => address.port(),
                Err(error) => {
                    let _ = ready_tx.send(Err(error.to_string()));
                    return;
                }
            };
            let _ = ready_tx.send(Ok(local_port));
            let mut axum_shutdown_rx = shutdown_rx.clone();
            let web_transport_shutdown_rx = shutdown_rx.clone();

            let mut app = Router::new()
                .fallback(any(handle_validated_request))
                .layer(middleware::from_fn_with_state(
                    runtime_state.clone(),
                    validate_request_middleware,
                ))
                .with_state(runtime_state.clone());
            if let Some(cors_layer) = cors_layer {
                app = app.layer(cors_layer);
            }
            let server = axum::serve(listener, app).with_graceful_shutdown(async move {
                let _ = axum_shutdown_rx.changed().await;
            });

            tokio::select! {
                result = server => {
                    if let Err(error) = result {
                        eprintln!("dart_http_server_runtime transport server failed: {error}");
                    }
                }
                result = run_web_transport_listener(
                    SocketAddr::new(bind_address.ip(), local_port),
                    web_transport_shutdown_rx,
                    runtime_state,
                ) => {
                    if let Err(error) = result {
                        eprintln!("dart_http_server_runtime WebTransport listener failed: {error}");
                    }
                }
            }
        });
    });

    match ready_rx.recv() {
        Ok(Ok(bound_port)) => {
            SERVER_STATES.lock().unwrap().insert(
                server_id,
                ServerState {
                    shutdown_tx: Some(shutdown_tx),
                    join_handle: Some(join_handle),
                },
            );
            (server_id << 16) | i64::from(bound_port)
        }
        Ok(Err(error)) => {
            eprintln!("dart_http_server_runtime transport startup failed: {error}");
            let _ = join_handle.join();
            -1
        }
        Err(error) => {
            eprintln!("dart_http_server_runtime transport startup failed: {error}");
            let _ = join_handle.join();
            -1
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_stop_server() {
    let server_ids = SERVER_STATES
        .lock()
        .unwrap()
        .keys()
        .copied()
        .collect::<Vec<_>>();
    for server_id in server_ids {
        dart_http_server_runtime_stop_server_by_id(server_id);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_stop_server_by_id(server_id: i64) {
    {
        let mut pending = PENDING_REQUESTS.lock().unwrap();
        let request_ids = pending
            .iter()
            .filter_map(|(request_id, request)| {
                (request.server_id == server_id).then_some(*request_id)
            })
            .collect::<Vec<_>>();
        for request_id in request_ids {
            let Some(request) = pending.remove(&request_id) else {
                continue;
            };
            let _ = request
                .response_tx
                .send(PendingResponseMessage::Http(TransportResponse {
                    status: 503,
                    content_type: "text/plain; charset=utf-8".to_string(),
                    body: b"Server stopped".to_vec(),
                    headers: Vec::new(),
                }));
            let _ = request.response_tx.send(PendingResponseMessage::Close);
        }
    }

    {
        let mut sessions = WEB_SOCKET_SESSIONS.lock().unwrap();
        let session_ids = sessions
            .iter()
            .filter_map(|(session_id, session)| {
                (session.server_id == server_id).then_some(*session_id)
            })
            .collect::<Vec<_>>();
        for session_id in session_ids {
            let Some(session) = sessions.remove(&session_id) else {
                continue;
            };
            let _ = session.command_tx.send(WebSocketCommand::Close {
                code: Some(1012),
                reason: Some("Server stopped".to_string()),
            });
        }
    }

    {
        let mut sessions = WEB_TRANSPORT_SESSIONS.lock().unwrap();
        let session_ids = sessions
            .iter()
            .filter_map(|(session_id, session)| {
                (session.server_id == server_id).then_some(*session_id)
            })
            .collect::<Vec<_>>();
        for session_id in session_ids {
            let Some(session) = sessions.remove(&session_id) else {
                continue;
            };
            let _ = session.command_tx.send(WebTransportCommand::Close {
                code: Some(1012),
                reason: Some("Server stopped".to_string()),
            });
        }
    }

    let server_state = SERVER_STATES.lock().unwrap().remove(&server_id);
    if let Some(mut state) = server_state {
        if let Some(shutdown_tx) = state.shutdown_tx.take() {
            let _ = shutdown_tx.send(true);
        }
        let _ = state.join_handle.take();
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_take_request(
    request_id: i64,
) -> *mut NativeTransportRequest {
    let mut pending = PENDING_REQUESTS.lock().unwrap();
    let Some(request) = pending.get_mut(&request_id) else {
        return std::ptr::null_mut();
    };
    let Some(request) = request.request.take() else {
        return std::ptr::null_mut();
    };

    let handle = Box::new(NativeTransportRequestHandle::from_transport_request(
        request,
    ));
    Box::into_raw(handle).cast::<NativeTransportRequest>()
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_free_request(value: *mut NativeTransportRequest) {
    if value.is_null() {
        return;
    }

    unsafe {
        let _ = Box::from_raw(value.cast::<NativeTransportRequestHandle>());
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_take_request_body_stream(
    request: *mut NativeTransportRequest,
    out_stream: *mut std::ffi::c_void,
) -> bool {
    if request.is_null() || out_stream.is_null() {
        return false;
    }
    let handle = unsafe { &mut *request.cast::<NativeTransportRequestHandle>() };
    let Some(stream) = handle.body_stream.take() else {
        return false;
    };
    unsafe {
        out_stream
            .cast::<NexByteStream>()
            .write(stream.into_descriptor());
    }
    true
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_accept_web_socket(
    request_id: i64,
    header_count: isize,
    headers: *const NativePair,
) -> bool {
    let headers = unsafe { read_pairs_vec(headers, header_count) };
    send_pending_response_message(
        request_id,
        PendingResponseMessage::WebSocketAccept { headers },
        true,
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_accept_web_transport(
    request_id: i64,
    header_count: isize,
    headers: *const NativePair,
) -> bool {
    let headers = unsafe { read_pairs_vec(headers, header_count) };
    send_pending_response_message(
        request_id,
        PendingResponseMessage::WebSocketAccept { headers },
        true,
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_start_sse_response(
    request_id: i64,
    status: i32,
    header_count: isize,
    headers: *const NativePair,
) -> bool {
    let headers = unsafe { read_pairs_vec(headers, header_count) };
    send_pending_response_message(
        request_id,
        PendingResponseMessage::SseStart {
            status: status as u16,
            headers,
        },
        false,
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_send_sse_chunk(
    request_id: i64,
    chunk: *const c_char,
) -> bool {
    let Some(chunk) = (unsafe { read_c_string(chunk) }) else {
        return false;
    };

    send_pending_response_message(request_id, PendingResponseMessage::SseChunk(chunk), false)
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_finish_sse_response(request_id: i64) -> bool {
    send_pending_response_message(request_id, PendingResponseMessage::Close, true)
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_start_binary_stream_response(
    request_id: i64,
    status: i32,
    content_type: *const c_char,
    content_length: i64,
    header_count: isize,
    headers: *const NativePair,
) -> bool {
    let Some(content_type) = (unsafe { read_c_string(content_type) }) else {
        return false;
    };
    let headers = unsafe { read_pairs_vec(headers, header_count) };
    send_pending_response_message(
        request_id,
        PendingResponseMessage::BinaryStart {
            status: status as u16,
            content_type,
            content_length: u64::try_from(content_length).ok(),
            headers,
        },
        false,
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_send_binary_stream_chunk(
    request_id: i64,
    chunk: NativeBytes,
) -> bool {
    let Some(chunk) = (unsafe { read_native_bytes(chunk) }) else {
        return false;
    };
    let (consumed_tx, consumed_rx) = std_mpsc::sync_channel(0);
    if !send_pending_response_message(
        request_id,
        PendingResponseMessage::BinaryChunk {
            bytes: chunk.to_vec(),
            consumed_tx,
        },
        false,
    ) {
        return false;
    }
    consumed_rx.recv().is_ok()
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_finish_binary_stream_response(request_id: i64) -> bool {
    send_pending_response_message(request_id, PendingResponseMessage::Close, true)
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_start_native_binary_stream_response(
    request_id: i64,
    status: i32,
    content_type: *const c_char,
    content_length: i64,
    header_count: isize,
    headers: *const NativePair,
    stream: *const NexByteStream,
) -> bool {
    let Some(content_type) = (unsafe { read_c_string(content_type) }) else {
        return false;
    };
    if stream.is_null() {
        return false;
    }
    let stream = unsafe { std::ptr::read(stream) };
    let valid = stream.is_valid()
        && stream.capabilities & NEX_CAPABILITY_THREAD_SAFE != 0
        && stream.capabilities & NEX_CAPABILITY_CONCURRENT_CANCEL != 0
        && stream.cancel.is_some();
    if !valid {
        release_rejected_native_stream(stream);
        return false;
    }
    let stream = match unsafe { AdoptedByteStream::adopt(stream) } {
        Ok(stream) if stream.cancel_handle().is_some() => stream,
        Ok(stream) => {
            stream.cancel();
            return false;
        }
        Err(failure) => {
            release_rejected_native_stream(failure.into_descriptor());
            return false;
        }
    };
    let headers = unsafe { read_pairs_vec(headers, header_count) };
    send_pending_response_message(
        request_id,
        PendingResponseMessage::NativeBinaryStart {
            status: status as u16,
            content_type,
            content_length: u64::try_from(content_length).ok(),
            headers,
            stream,
        },
        true,
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_parse_multipart(
    request: *mut NativeTransportRequest,
    content_type: *const c_char,
) -> *mut NativeMultipartForm {
    clear_last_error();

    if request.is_null() {
        set_last_error("Missing native request.");
        return std::ptr::null_mut();
    }

    let Some(content_type) = (unsafe { read_c_string(content_type) }) else {
        set_last_error("Missing request content type.");
        return std::ptr::null_mut();
    };

    let boundary = match parse_multipart_boundary(&content_type) {
        Ok(boundary) => boundary,
        Err(error) => {
            set_last_error(error);
            return std::ptr::null_mut();
        }
    };

    let request_handle = unsafe { &mut *request.cast::<NativeTransportRequestHandle>() };
    let body = request_handle.request.body;
    if body.ptr.is_null() || body.len <= 0 {
        set_last_error("Request body is empty.");
        return std::ptr::null_mut();
    }

    let body_bytes = unsafe { std::slice::from_raw_parts(body.ptr, body.len as usize) };
    let parsed_form = match parse_multipart_form(body_bytes, &boundary) {
        Ok(form) => form,
        Err(error) => {
            set_last_error(error);
            return std::ptr::null_mut();
        }
    };

    let handle = Box::new(NativeMultipartFormHandle::from_parsed_form(
        parsed_form,
        body.ptr,
    ));
    Box::into_raw(handle).cast::<NativeMultipartForm>()
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_free_multipart_form(value: *mut NativeMultipartForm) {
    if value.is_null() {
        return;
    }

    unsafe {
        let _ = Box::from_raw(value.cast::<NativeMultipartFormHandle>());
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_take_web_socket_connection(
    session_id: i64,
) -> *mut NativeWebSocketConnection {
    let mut sessions = WEB_SOCKET_SESSIONS.lock().unwrap();
    let Some(session) = sessions.get_mut(&session_id) else {
        return std::ptr::null_mut();
    };
    let Some(connection) = session.connection.take() else {
        return std::ptr::null_mut();
    };

    let handle = Box::new(NativeWebSocketConnectionHandle::from_connection(connection));
    Box::into_raw(handle).cast::<NativeWebSocketConnection>()
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_free_web_socket_connection(
    value: *mut NativeWebSocketConnection,
) {
    if value.is_null() {
        return;
    }

    unsafe {
        let _ = Box::from_raw(value.cast::<NativeWebSocketConnectionHandle>());
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_take_web_socket_message(
    session_id: i64,
) -> *mut NativeWebSocketMessage {
    let mut sessions = WEB_SOCKET_SESSIONS.lock().unwrap();
    let Some(session) = sessions.get_mut(&session_id) else {
        return std::ptr::null_mut();
    };
    let Some(message) = session.messages.pop_front() else {
        return std::ptr::null_mut();
    };
    session.pending_bytes = session.pending_bytes.saturating_sub(message.body.len());

    let handle = Box::new(NativeWebSocketMessageHandle::from_message(message));
    Box::into_raw(handle).cast::<NativeWebSocketMessage>()
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_free_web_socket_message(
    value: *mut NativeWebSocketMessage,
) {
    if value.is_null() {
        return;
    }

    unsafe {
        let _ = Box::from_raw(value.cast::<NativeWebSocketMessageHandle>());
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_take_web_transport_connection(
    session_id: i64,
) -> *mut NativeWebTransportConnection {
    let mut sessions = WEB_TRANSPORT_SESSIONS.lock().unwrap();
    let Some(session) = sessions.get_mut(&session_id) else {
        return std::ptr::null_mut();
    };
    let Some(connection) = session.connection.take() else {
        return std::ptr::null_mut();
    };

    let handle = Box::new(NativeWebTransportConnectionHandle::from_connection(
        connection,
    ));
    Box::into_raw(handle).cast::<NativeWebTransportConnection>()
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_free_web_transport_connection(
    value: *mut NativeWebTransportConnection,
) {
    if value.is_null() {
        return;
    }

    unsafe {
        let _ = Box::from_raw(value.cast::<NativeWebTransportConnectionHandle>());
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_take_web_transport_datagram(
    session_id: i64,
) -> *mut NativeWebTransportDatagram {
    let mut sessions = WEB_TRANSPORT_SESSIONS.lock().unwrap();
    let Some(session) = sessions.get_mut(&session_id) else {
        return std::ptr::null_mut();
    };
    let Some(datagram) = session.datagrams.pop_front() else {
        return std::ptr::null_mut();
    };
    session.pending_bytes = session.pending_bytes.saturating_sub(datagram.body.len());

    let handle = Box::new(NativeWebTransportDatagramHandle::from_datagram(datagram));
    Box::into_raw(handle).cast::<NativeWebTransportDatagram>()
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_take_web_transport_stream(
    session_id: i64,
) -> *mut NativeWebTransportStream {
    let mut sessions = WEB_TRANSPORT_SESSIONS.lock().unwrap();
    let Some(session) = sessions.get_mut(&session_id) else {
        return std::ptr::null_mut();
    };
    let Some(stream) = session.streams.pop_front() else {
        return std::ptr::null_mut();
    };
    session.pending_bytes = session.pending_bytes.saturating_sub(stream.body.len());

    let handle = Box::new(NativeWebTransportStreamHandle::from_stream(stream));
    Box::into_raw(handle).cast::<NativeWebTransportStream>()
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_free_web_transport_stream(
    value: *mut NativeWebTransportStream,
) {
    if value.is_null() {
        return;
    }

    unsafe {
        let _ = Box::from_raw(value.cast::<NativeWebTransportStreamHandle>());
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_take_web_transport_stream_info(
    stream_id: i64,
) -> *mut NativeWebTransportStreamInfo {
    let Some(info) = WEB_TRANSPORT_OPENED_STREAMS
        .lock()
        .unwrap()
        .remove(&stream_id)
    else {
        return std::ptr::null_mut();
    };
    Box::into_raw(Box::new(NativeWebTransportStreamInfo {
        session_id: info.session_id,
        stream_id: info.stream_id,
        protocol_id: info.protocol_id,
        kind: info.kind as u8,
    }))
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_free_web_transport_stream_info(
    value: *mut NativeWebTransportStreamInfo,
) {
    if !value.is_null() {
        unsafe { drop(Box::from_raw(value)) };
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_take_web_transport_stream_chunk(
    stream_id: i64,
) -> *mut NativeWebTransportStreamChunk {
    let body = {
        let mut streams = WEB_TRANSPORT_STREAMS.lock().unwrap();
        streams.get_mut(&stream_id).and_then(|stream| {
            let body = stream.chunks.pop_front()?;
            stream.pending_bytes = stream.pending_bytes.saturating_sub(body.len());
            Some(body)
        })
    };
    remove_web_transport_stream_if_complete(stream_id);
    let Some(body) = body else {
        return std::ptr::null_mut();
    };
    let handle = Box::new(NativeWebTransportStreamChunkHandle::new(stream_id, body));
    Box::into_raw(handle).cast::<NativeWebTransportStreamChunk>()
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_free_web_transport_stream_chunk(
    value: *mut NativeWebTransportStreamChunk,
) {
    if !value.is_null() {
        unsafe {
            drop(Box::from_raw(
                value.cast::<NativeWebTransportStreamChunkHandle>(),
            ))
        };
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_take_web_transport_stream_terminal(
    stream_id: i64,
) -> *mut NativeWebTransportStreamTerminal {
    let terminal = {
        let mut streams = WEB_TRANSPORT_STREAMS.lock().unwrap();
        streams
            .get_mut(&stream_id)
            .and_then(|stream| stream.terminal.take())
    };
    remove_web_transport_stream_if_complete(stream_id);
    let Some(terminal) = terminal else {
        return std::ptr::null_mut();
    };
    let handle = Box::new(NativeWebTransportStreamTerminalHandle::new(
        stream_id, terminal,
    ));
    Box::into_raw(handle).cast::<NativeWebTransportStreamTerminal>()
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_free_web_transport_stream_terminal(
    value: *mut NativeWebTransportStreamTerminal,
) {
    if !value.is_null() {
        unsafe {
            drop(Box::from_raw(
                value.cast::<NativeWebTransportStreamTerminalHandle>(),
            ))
        };
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_take_web_transport_operation(
    operation_id: i64,
) -> *mut NativeWebTransportOperation {
    let operation = WEB_TRANSPORT_OPERATIONS
        .lock()
        .unwrap()
        .remove(&operation_id);
    let Some(operation) = operation else {
        return std::ptr::null_mut();
    };
    let handle = Box::new(NativeWebTransportOperationHandle::new(operation));
    Box::into_raw(handle).cast::<NativeWebTransportOperation>()
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_free_web_transport_operation(
    value: *mut NativeWebTransportOperation,
) {
    if !value.is_null() {
        unsafe {
            drop(Box::from_raw(
                value.cast::<NativeWebTransportOperationHandle>(),
            ))
        };
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_web_transport_open_unidirectional_stream(
    session_id: i64,
) -> i64 {
    submit_web_transport_session_operation(session_id, |operation_id| {
        WebTransportCommand::OpenUnidirectional { operation_id }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_web_transport_open_bidirectional_stream(
    session_id: i64,
) -> i64 {
    submit_web_transport_session_operation(session_id, |operation_id| {
        WebTransportCommand::OpenBidirectional { operation_id }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_web_transport_stream_write(
    stream_id: i64,
    body: NativeBytes,
) -> i64 {
    let Some(body) = (unsafe { read_native_bytes(body) }) else {
        return 0;
    };
    submit_web_transport_send_operation(stream_id, |operation_id| {
        WebTransportStreamCommand::Write {
            operation_id,
            body: body.to_vec(),
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_web_transport_stream_finish(stream_id: i64) -> i64 {
    submit_web_transport_send_operation(stream_id, |operation_id| {
        WebTransportStreamCommand::Finish { operation_id }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_web_transport_stream_reset(
    stream_id: i64,
    error_code: u32,
) -> i64 {
    submit_web_transport_send_operation(stream_id, |operation_id| {
        WebTransportStreamCommand::Reset {
            operation_id,
            error_code,
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_web_transport_stream_stop(
    stream_id: i64,
    error_code: u32,
) -> i64 {
    let operation_id = NEXT_WEB_TRANSPORT_OPERATION_ID.fetch_add(1, Ordering::Relaxed);
    let (info, runtime_state, stop_tx) = {
        let streams = WEB_TRANSPORT_STREAMS.lock().unwrap();
        let Some(stream) = streams.get(&stream_id) else {
            return 0;
        };
        (
            stream.info,
            stream.runtime_state.clone(),
            stream.stop_tx.clone(),
        )
    };
    let Some(stop_tx) = stop_tx else { return 0 };
    if stop_tx.send(error_code).is_err() {
        return 0;
    }
    push_web_transport_operation(
        WebTransportOperationResult {
            operation_id,
            session_id: info.session_id,
            stream_id,
            protocol_id: info.protocol_id,
            kind: WebTransportOperationKind::Stop,
            error: None,
        },
        &runtime_state,
    );
    operation_id
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_free_web_transport_datagram(
    value: *mut NativeWebTransportDatagram,
) {
    if value.is_null() {
        return;
    }

    unsafe {
        let _ = Box::from_raw(value.cast::<NativeWebTransportDatagramHandle>());
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_web_transport_send_datagram(
    session_id: i64,
    body: NativeBytes,
) -> bool {
    let Some(body) = (unsafe { read_native_bytes(body) }) else {
        return false;
    };
    let command_tx = {
        let sessions = WEB_TRANSPORT_SESSIONS.lock().unwrap();
        let Some(session) = sessions.get(&session_id) else {
            return false;
        };
        session.command_tx.clone()
    };

    command_tx
        .send(WebTransportCommand::SendDatagram(body.to_vec()))
        .is_ok()
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_web_transport_send_stream(
    session_id: i64,
    body: NativeBytes,
) -> bool {
    let Some(body) = (unsafe { read_native_bytes(body) }) else {
        return false;
    };
    let command_tx = {
        let sessions = WEB_TRANSPORT_SESSIONS.lock().unwrap();
        let Some(session) = sessions.get(&session_id) else {
            return false;
        };
        session.command_tx.clone()
    };

    command_tx
        .send(WebTransportCommand::SendStream(body.to_vec()))
        .is_ok()
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_web_transport_close(
    session_id: i64,
    code: i32,
    reason: *const c_char,
) -> bool {
    let reason = unsafe { read_optional_c_string(reason) };
    let command_tx = {
        let sessions = WEB_TRANSPORT_SESSIONS.lock().unwrap();
        let Some(session) = sessions.get(&session_id) else {
            return false;
        };
        session.command_tx.clone()
    };

    command_tx
        .send(WebTransportCommand::Close {
            code: if code <= 0 { None } else { Some(code as u32) },
            reason,
        })
        .is_ok()
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_web_socket_send_text(
    session_id: i64,
    text: *const c_char,
) -> bool {
    let Some(text) = (unsafe { read_c_string(text) }) else {
        return false;
    };
    let command_tx = {
        let sessions = WEB_SOCKET_SESSIONS.lock().unwrap();
        let Some(session) = sessions.get(&session_id) else {
            return false;
        };
        session.command_tx.clone()
    };

    command_tx.send(WebSocketCommand::SendText(text)).is_ok()
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_web_socket_send_binary(
    session_id: i64,
    body: NativeBytes,
) -> bool {
    let Some(body) = (unsafe { read_native_bytes(body) }) else {
        return false;
    };
    let command_tx = {
        let sessions = WEB_SOCKET_SESSIONS.lock().unwrap();
        let Some(session) = sessions.get(&session_id) else {
            return false;
        };
        session.command_tx.clone()
    };

    command_tx
        .send(WebSocketCommand::SendBinary(body.to_vec()))
        .is_ok()
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_web_socket_close(
    session_id: i64,
    code: i32,
    reason: *const c_char,
) -> bool {
    let reason = unsafe { read_optional_c_string(reason) };
    let command_tx = {
        let sessions = WEB_SOCKET_SESSIONS.lock().unwrap();
        let Some(session) = sessions.get(&session_id) else {
            return false;
        };
        session.command_tx.clone()
    };

    command_tx
        .send(WebSocketCommand::Close {
            code: if code <= 0 { None } else { Some(code as u16) },
            reason,
        })
        .is_ok()
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_take_last_error() -> *mut c_char {
    let Some(message) = LAST_ERROR.lock().unwrap().take() else {
        return std::ptr::null_mut();
    };

    match CString::new(message) {
        Ok(message) => message.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_free_string(value: *mut c_char) {
    if value.is_null() {
        return;
    }

    unsafe {
        let _ = CString::from_raw(value);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_server_runtime_send_response(
    request_id: i64,
    status: i32,
    content_type: *const c_char,
    body: NativeBytes,
    header_count: isize,
    headers: *const NativePair,
) -> bool {
    let content_type = unsafe { read_c_string(content_type) };
    let body = unsafe { read_native_bytes(body) };
    let Some(content_type) = content_type else {
        return false;
    };
    let Some(body) = body else {
        return false;
    };
    let headers = unsafe { read_pairs_vec(headers, header_count) };

    send_pending_response_message(
        request_id,
        PendingResponseMessage::Http(TransportResponse {
            status: status as u16,
            content_type,
            body: body.to_vec(),
            headers,
        }),
        true,
    )
}

async fn validate_request_middleware(
    State(runtime_state): State<ServerRuntimeState>,
    request: Request<Body>,
    next: Next,
) -> Response<Body> {
    let (parts, body) = request.into_parts();
    let requested_kind = if wants_web_socket_upgrade(&parts.headers) {
        RouteTransportKind::WebSocket
    } else {
        RouteTransportKind::Http
    };

    let route_match = match match_route(
        &runtime_state,
        parts.method.as_str(),
        parts.uri.path(),
        requested_kind,
    ) {
        Some(route_match) => route_match,
        None => {
            return response(
                StatusCode::NOT_FOUND,
                "text/plain; charset=utf-8",
                "Not found".to_string(),
            );
        }
    };
    let method = parts.method.as_str().to_string();
    let path = parts.uri.path().to_string();
    let query = parse_query(parts.uri.query());
    let headers = collect_headers(&parts.headers);

    if let Err(error_response) = validate_string_map(
        &route_match.path_params,
        route_match.params_schema_id.as_deref(),
        "Path parameters",
        &runtime_state,
    ) {
        return error_response;
    }
    if let Err(error_response) = validate_string_map(
        &query,
        route_match.query_schema_id.as_deref(),
        "Query parameters",
        &runtime_state,
    ) {
        return error_response;
    }
    if let Err(error_response) = validate_string_map(
        &headers,
        route_match.headers_schema_id.as_deref(),
        "Headers",
        &runtime_state,
    ) {
        return error_response;
    }

    match route_match.kind {
        RouteTransportKind::Http | RouteTransportKind::NativeHttp => {
            let streams_body = route_match.kind == RouteTransportKind::Http
                && route_match
                    .request_body
                    .as_ref()
                    .is_some_and(|request_body| request_body.streaming);
            if streams_body {
                let request_body = route_match
                    .request_body
                    .as_ref()
                    .expect("streaming route has a request body");
                let actual_content_type = parts
                    .headers
                    .get(header::CONTENT_TYPE)
                    .and_then(|value| value.to_str().ok());
                if !content_type_matches(actual_content_type, &request_body.content_type) {
                    return response(
                        StatusCode::UNSUPPORTED_MEDIA_TYPE,
                        "text/plain; charset=utf-8",
                        format!("Expected {}", request_body.content_type),
                    );
                }
                let mut request = Request::from_parts(parts, body);
                request.extensions_mut().insert(ValidatedRouteRequest {
                    route_match,
                    method,
                    path,
                    query,
                    headers,
                    body: None,
                    runtime_state,
                });
                return next.run(request).await;
            }
            let body_bytes = match axum::body::to_bytes(body, usize::MAX).await {
                Ok(bytes) => bytes,
                Err(_) => {
                    return response(
                        StatusCode::INTERNAL_SERVER_ERROR,
                        "text/plain; charset=utf-8",
                        "Failed to read request body".to_string(),
                    );
                }
            };
            let body = match validate_and_read_body(
                &parts.headers,
                body_bytes,
                route_match.request_body.as_ref(),
            ) {
                Ok(body) => body,
                Err(error_response) => return error_response,
            };
            if let Some(request_body) = route_match.request_body.as_ref()
                && let Err(error_response) =
                    validate_request_body(&body, request_body, &runtime_state)
            {
                return error_response;
            }

            let mut request = Request::from_parts(parts, Body::empty());
            request.extensions_mut().insert(ValidatedRouteRequest {
                route_match,
                method,
                path,
                query,
                headers,
                body: Some(body),
                runtime_state,
            });
            next.run(request).await
        }
        RouteTransportKind::WebSocket | RouteTransportKind::WebTransport => {
            let mut request = Request::from_parts(parts, body);
            request.extensions_mut().insert(ValidatedRouteRequest {
                route_match,
                method,
                path,
                query,
                headers,
                body: None,
                runtime_state,
            });
            next.run(request).await
        }
    }
}

async fn handle_validated_request(mut request: Request<Body>) -> Response<Body> {
    let Some(validated) = request.extensions_mut().remove::<ValidatedRouteRequest>() else {
        return response(
            StatusCode::INTERNAL_SERVER_ERROR,
            "text/plain; charset=utf-8",
            "Request validation context is missing".to_string(),
        );
    };

    match validated.route_match.kind {
        RouteTransportKind::NativeHttp => {
            handle_native_http_request(
                validated.route_match,
                &validated.method,
                &validated.path,
                validated.query,
                validated.headers,
                validated.body.unwrap_or_else(ValidatedBody::none),
            )
            .await
        }
        RouteTransportKind::Http => {
            let streams_body = validated
                .route_match
                .request_body
                .as_ref()
                .is_some_and(|request_body| request_body.streaming);
            let body_stream = streams_body.then(|| request.into_body());
            handle_http_request(
                validated.route_match,
                validated.query,
                validated.headers,
                validated.body.unwrap_or_else(ValidatedBody::none),
                body_stream,
                &validated.runtime_state,
            )
            .await
        }
        RouteTransportKind::WebSocket => {
            let (parts, _body) = request.into_parts();
            handle_web_socket_request(
                parts,
                validated.route_match,
                validated.query,
                validated.headers,
                validated.runtime_state,
            )
            .await
        }
        RouteTransportKind::WebTransport => response(
            StatusCode::NOT_IMPLEMENTED,
            "text/plain; charset=utf-8",
            "WebTransport routes require the HTTP/3 transport listener.".to_string(),
        ),
    }
}

async fn handle_http_request(
    route_match: NativeRouteMatch,
    query: HashMap<String, String>,
    headers: HashMap<String, String>,
    body: ValidatedBody,
    body_stream: Option<Body>,
    runtime_state: &ServerRuntimeState,
) -> Response<Body> {
    let transport_request = TransportRequest {
        route_id: route_match.route_id,
        path_params: route_match.path_params,
        query,
        headers,
        body: body.bytes,
        body_stream: body_stream.map(ProducedIncomingBodyStream::from_body),
        request_kind: NativeRequestKind::Http,
        body_kind: body.kind,
    };

    let (_request_id, mut response_rx) =
        match dispatch_request_to_dart(transport_request, runtime_state) {
            Ok(value) => value,
            Err(error_response) => return error_response,
        };

    match response_rx.recv().await {
        Some(PendingResponseMessage::Http(transport_response)) => response_body_with_headers(
            StatusCode::from_u16(transport_response.status)
                .unwrap_or(StatusCode::INTERNAL_SERVER_ERROR),
            &transport_response.content_type,
            &transport_response.headers,
            Body::from(transport_response.body),
        ),
        Some(PendingResponseMessage::SseStart { status, headers }) => {
            let stream = async_stream::stream! {
                while let Some(message) = response_rx.recv().await {
                    match message {
                        PendingResponseMessage::SseChunk(chunk) => {
                            yield Ok::<Bytes, std::convert::Infallible>(Bytes::from(chunk));
                        }
                        PendingResponseMessage::Close => break,
                        PendingResponseMessage::Http(_)
                        | PendingResponseMessage::SseStart { .. }
                        | PendingResponseMessage::BinaryStart { .. }
                        | PendingResponseMessage::BinaryChunk { .. }
                        | PendingResponseMessage::NativeBinaryStart { .. }
                        | PendingResponseMessage::WebSocketAccept { .. } => break,
                    }
                }
            };

            response_body_with_headers(
                StatusCode::from_u16(status).unwrap_or(StatusCode::OK),
                "text/event-stream; charset=utf-8",
                &headers,
                Body::from_stream(stream),
            )
        }
        Some(PendingResponseMessage::BinaryStart {
            status,
            content_type,
            content_length,
            mut headers,
        }) => {
            if let Some(content_length) = content_length {
                headers.push((
                    header::CONTENT_LENGTH.as_str().to_string(),
                    content_length.to_string(),
                ));
            }
            let stream = async_stream::stream! {
                while let Some(message) = response_rx.recv().await {
                    match message {
                        PendingResponseMessage::BinaryChunk { bytes, consumed_tx } => {
                            let _ = consumed_tx.send(());
                            yield Ok::<Bytes, std::convert::Infallible>(Bytes::from(bytes));
                        }
                        PendingResponseMessage::Close => break,
                        PendingResponseMessage::Http(_)
                        | PendingResponseMessage::SseStart { .. }
                        | PendingResponseMessage::SseChunk(_)
                        | PendingResponseMessage::BinaryStart { .. }
                        | PendingResponseMessage::NativeBinaryStart { .. }
                        | PendingResponseMessage::WebSocketAccept { .. } => break,
                    }
                }
            };

            response_body_with_headers(
                StatusCode::from_u16(status).unwrap_or(StatusCode::OK),
                &content_type,
                &headers,
                Body::from_stream(stream),
            )
        }
        Some(PendingResponseMessage::NativeBinaryStart {
            status,
            content_type,
            content_length,
            mut headers,
            stream,
        }) => {
            if let Some(content_length) = content_length {
                headers.push((
                    header::CONTENT_LENGTH.as_str().to_string(),
                    content_length.to_string(),
                ));
            }
            let cancel = stream
                .cancel_handle()
                .expect("native HTTP response streams require concurrent cancellation");
            let (sender, mut receiver) = mpsc::channel(1);
            tokio::task::spawn_blocking(move || {
                run_native_response_worker(stream, sender, content_length)
            });
            let stream = async_stream::stream! {
                let _cancel_on_drop = CancelNativeResponseOnDrop(Some(cancel));
                while let Some(result) = receiver.recv().await {
                    yield result;
                }
            };

            response_body_with_headers(
                StatusCode::from_u16(status).unwrap_or(StatusCode::OK),
                &content_type,
                &headers,
                Body::from_stream(stream),
            )
        }
        Some(PendingResponseMessage::Close) | None => response(
            StatusCode::INTERNAL_SERVER_ERROR,
            "text/plain; charset=utf-8",
            "Request handling failed".to_string(),
        ),
        Some(PendingResponseMessage::SseChunk(_)) => response(
            StatusCode::INTERNAL_SERVER_ERROR,
            "text/plain; charset=utf-8",
            "Unexpected SSE chunk before SSE start".to_string(),
        ),
        Some(PendingResponseMessage::BinaryChunk { .. }) => response(
            StatusCode::INTERNAL_SERVER_ERROR,
            "text/plain; charset=utf-8",
            "Unexpected binary chunk before binary stream start".to_string(),
        ),
        Some(PendingResponseMessage::WebSocketAccept { .. }) => response(
            StatusCode::INTERNAL_SERVER_ERROR,
            "text/plain; charset=utf-8",
            "Unexpected WebSocket response for HTTP request".to_string(),
        ),
    }
}

async fn handle_native_http_request(
    route_match: NativeRouteMatch,
    method: &str,
    path: &str,
    query: HashMap<String, String>,
    headers: HashMap<String, String>,
    body: ValidatedBody,
) -> Response<Body> {
    let NativeRouteMatch {
        native_handler,
        path_params,
        ..
    } = route_match;
    let Some(native_handler) = native_handler else {
        return response(
            StatusCode::INTERNAL_SERVER_ERROR,
            "text/plain; charset=utf-8",
            "Native route is missing handler metadata".to_string(),
        );
    };

    let handler_path = match native_handler_path(
        path,
        native_handler.handler_path_segments.as_deref(),
        &path_params,
    ) {
        Ok(path) => path,
        Err(message) => {
            return response(
                StatusCode::INTERNAL_SERVER_ERROR,
                "text/plain; charset=utf-8",
                message,
            );
        }
    };
    let path = CString::new(handler_path).unwrap_or_default();
    let query_pairs = owned_pairs_from_map(query);
    let query_storage = native_pairs_from_owned(&query_pairs);
    let header_pairs = owned_pairs_from_map(headers);
    let header_storage = native_pairs_from_owned(&header_pairs);
    let body_bytes = body.bytes.unwrap_or_default();
    let body_ptr = if body_bytes.is_empty() {
        std::ptr::null()
    } else {
        body_bytes.as_ptr()
    };

    let Some(method) = NativeHttpMethod::from_name(method) else {
        return response(
            StatusCode::METHOD_NOT_ALLOWED,
            "text/plain; charset=utf-8",
            "Unsupported HTTP method".to_string(),
        );
    };
    let request_body = NativeBytes {
        ptr: body_ptr,
        len: body_bytes.len() as isize,
    };
    let native_request = NativeHttpRequest {
        method: method.code(),
        path: path.as_ptr(),
        query_count: query_storage.len() as isize,
        query: boxed_pairs_ptr(&query_storage),
        header_count: header_storage.len() as isize,
        headers: boxed_pairs_ptr(&header_storage),
        body: request_body,
    };
    let response_ptr = unsafe { (native_handler.handler)(native_handler.handle, &native_request) };
    if response_ptr.is_null() {
        return response(
            StatusCode::INTERNAL_SERVER_ERROR,
            "text/plain; charset=utf-8",
            "Native route handler failed".to_string(),
        );
    }

    let native_response = unsafe { &*response_ptr };
    let status =
        StatusCode::from_u16(native_response.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    let content_type = unsafe { read_native_string(native_response.content_type) }
        .unwrap_or_else(|| "application/octet-stream".to_string());
    let response_body = unsafe { read_native_bytes(native_response.body) }
        .map(|bytes| bytes.to_vec())
        .unwrap_or_default();
    let response_headers =
        unsafe { read_pairs_vec(native_response.headers, native_response.header_count) };
    unsafe {
        (native_handler.free_response)(response_ptr);
    }

    response_body_with_headers(
        status,
        &content_type,
        &response_headers,
        Body::from(response_body),
    )
}

fn native_handler_path(
    public_path: &str,
    handler_path_segments: Option<&[CompiledRouteSegment]>,
    path_params: &HashMap<String, String>,
) -> Result<String, String> {
    let Some(handler_path_segments) = handler_path_segments else {
        return Ok(public_path.to_string());
    };

    if handler_path_segments.is_empty() {
        return Ok("/".to_string());
    }

    let mut path = String::new();
    for segment in handler_path_segments {
        path.push('/');
        match segment {
            CompiledRouteSegment::Literal(value) => path.push_str(value),
            CompiledRouteSegment::Parameter(name) => {
                let Some(value) = path_params.get(name) else {
                    return Err(format!(
                        "Native route handler path references missing parameter '{name}'."
                    ));
                };
                path.push_str(value);
            }
            CompiledRouteSegment::Wildcard(name) => {
                let Some(value) = path_params.get(name) else {
                    return Err(format!(
                        "Native route handler path references missing wildcard parameter '{name}'."
                    ));
                };
                path.push_str(value);
            }
        }
    }

    Ok(path)
}

async fn handle_web_socket_request(
    mut parts: http::request::Parts,
    route_match: NativeRouteMatch,
    query: HashMap<String, String>,
    headers: HashMap<String, String>,
    runtime_state: ServerRuntimeState,
) -> Response<Body> {
    let max_pending_messages = route_match.max_pending_messages;
    let max_pending_bytes = route_match.max_pending_bytes;
    let route_id = route_match.route_id;
    let path_params = route_match.path_params;
    let transport_request = TransportRequest {
        route_id: route_id.clone(),
        path_params: path_params.clone(),
        query: query.clone(),
        headers: headers.clone(),
        body: None,
        body_stream: None,
        request_kind: NativeRequestKind::WebSocket,
        body_kind: NativeBodyKind::None,
    };

    let (request_id, mut response_rx) =
        match dispatch_request_to_dart(transport_request, &runtime_state) {
            Ok(value) => value,
            Err(error_response) => return error_response,
        };

    match response_rx.recv().await {
        Some(PendingResponseMessage::Http(transport_response)) => response_body_with_headers(
            StatusCode::from_u16(transport_response.status)
                .unwrap_or(StatusCode::INTERNAL_SERVER_ERROR),
            &transport_response.content_type,
            &transport_response.headers,
            Body::from(transport_response.body),
        ),
        Some(PendingResponseMessage::WebSocketAccept {
            headers: response_headers,
        }) => {
            let websocket = match WebSocketUpgrade::from_request_parts(&mut parts, &()).await {
                Ok(websocket) => websocket,
                Err(rejection) => return rejection.into_response(),
            };

            let mut response = websocket
                .on_upgrade(move |socket| {
                    handle_web_socket_session(
                        socket,
                        request_id,
                        route_id,
                        path_params,
                        query,
                        headers,
                        max_pending_messages,
                        max_pending_bytes,
                        runtime_state,
                    )
                })
                .into_response();
            append_headers(response.headers_mut(), &response_headers);
            response
        }
        _ => response(
            StatusCode::INTERNAL_SERVER_ERROR,
            "text/plain; charset=utf-8",
            "WebSocket handshake failed".to_string(),
        ),
    }
}

async fn handle_web_socket_session(
    mut socket: WebSocket,
    request_id: i64,
    route_id: String,
    path_params: HashMap<String, String>,
    query: HashMap<String, String>,
    headers: HashMap<String, String>,
    max_pending_messages: usize,
    max_pending_bytes: usize,
    runtime_state: ServerRuntimeState,
) {
    let session_id = NEXT_WEB_SOCKET_SESSION_ID.fetch_add(1, Ordering::Relaxed);
    let (command_tx, mut command_rx) = mpsc::unbounded_channel::<WebSocketCommand>();
    {
        let mut sessions = WEB_SOCKET_SESSIONS.lock().unwrap();
        sessions.insert(
            session_id,
            WebSocketSessionState {
                server_id: runtime_state.server_id,
                connection: Some(WebSocketConnection {
                    session_id,
                    request_id,
                    route_id,
                    path_params,
                    query,
                    headers,
                }),
                messages: VecDeque::new(),
                pending_bytes: 0,
                max_pending_messages,
                max_pending_bytes,
                command_tx,
            },
        );
    }
    notify_transport_event(
        &runtime_state,
        TransportEventKind::WebSocketOpened,
        session_id,
    );

    loop {
        tokio::select! {
            incoming = socket.next() => {
                match incoming {
                    Some(Ok(Message::Text(text))) => {
                        let accepted = push_web_socket_message(
                            session_id,
                            WebSocketIncomingMessage {
                                session_id,
                                kind: WebSocketMessageKind::Text,
                                body: text.as_str().as_bytes().to_vec(),
                            },
                        );
                        if !accepted {
                            let _ = try_send_web_socket_close(
                                &mut socket,
                                Some(1013),
                                Some("incoming queue limit exceeded".to_string()),
                            ).await;
                            break;
                        }
                        notify_transport_event(&runtime_state, TransportEventKind::WebSocketMessageReady, session_id);
                    }
                    Some(Ok(Message::Binary(bytes))) => {
                        let accepted = push_web_socket_message(
                            session_id,
                            WebSocketIncomingMessage {
                                session_id,
                                kind: WebSocketMessageKind::Binary,
                                body: bytes.to_vec(),
                            },
                        );
                        if !accepted {
                            let _ = try_send_web_socket_close(
                                &mut socket,
                                Some(1013),
                                Some("incoming queue limit exceeded".to_string()),
                            ).await;
                            break;
                        }
                        notify_transport_event(&runtime_state, TransportEventKind::WebSocketMessageReady, session_id);
                    }
                    Some(Ok(Message::Close(_))) | None => break,
                    Some(Ok(Message::Ping(_))) | Some(Ok(Message::Pong(_))) => {}
                    Some(Err(_)) => break,
                }
            }
            command = command_rx.recv() => {
                match command {
                    Some(WebSocketCommand::SendText(text)) => {
                        if socket.send(Message::Text(text.into())).await.is_err() {
                            break;
                        }
                    }
                    Some(WebSocketCommand::SendBinary(body)) => {
                        if socket.send(Message::Binary(body.into())).await.is_err() {
                            break;
                        }
                    }
                    Some(WebSocketCommand::Close { code, reason }) => {
                        let _ = try_send_web_socket_close(&mut socket, code, reason).await;
                        break;
                    }
                    None => break,
                }
            }
        }
    }

    let _ = WEB_SOCKET_SESSIONS.lock().unwrap().remove(&session_id);
    notify_transport_event(
        &runtime_state,
        TransportEventKind::WebSocketClosed,
        session_id,
    );
}

async fn run_web_transport_listener(
    bind_address: SocketAddr,
    mut shutdown_rx: watch::Receiver<bool>,
    runtime_state: ServerRuntimeState,
) -> Result<(), String> {
    let identity = Identity::self_signed(["localhost", "127.0.0.1", "::1"])
        .map_err(|error| format!("Failed to create WebTransport TLS identity: {error}"))?;
    let config = WebTransportServerConfig::builder()
        .with_bind_address(bind_address)
        .with_identity(identity)
        .keep_alive_interval(Some(Duration::from_secs(3)))
        .build();
    let endpoint = WebTransportEndpoint::server(config)
        .map_err(|error| format!("Failed to bind WebTransport UDP listener: {error}"))?;

    loop {
        tokio::select! {
            _ = shutdown_rx.changed() => {
                endpoint.close(VarInt::from_u32(0), b"Server stopped");
                return Ok(());
            }
            incoming_session = endpoint.accept() => {
                let runtime_state = runtime_state.clone();
                tokio::spawn(async move {
                    if let Err(error) = handle_web_transport_incoming_session(incoming_session, runtime_state).await {
                        eprintln!("dart_http_server_runtime WebTransport session failed: {error}");
                    }
                });
            }
        }
    }
}

async fn handle_web_transport_incoming_session(
    incoming_session: wtransport::endpoint::IncomingSession,
    runtime_state: ServerRuntimeState,
) -> Result<(), String> {
    let session_request = incoming_session
        .await
        .map_err(|error| format!("Failed to read WebTransport session request: {error}"))?;
    let (path, query) = split_web_transport_path(session_request.path());
    let route_match = match match_route(
        &runtime_state,
        "GET",
        &path,
        RouteTransportKind::WebTransport,
    ) {
        Some(route_match) => route_match,
        None => {
            session_request.forbidden().await;
            return Ok(());
        }
    };
    let headers = session_request.headers().clone();
    let headers = collect_web_transport_headers(headers);
    let query = parse_query(query);

    if validate_string_map(
        &route_match.path_params,
        route_match.params_schema_id.as_deref(),
        "Path parameters",
        &runtime_state,
    )
    .is_err()
        || validate_string_map(
            &query,
            route_match.query_schema_id.as_deref(),
            "Query parameters",
            &runtime_state,
        )
        .is_err()
        || validate_string_map(
            &headers,
            route_match.headers_schema_id.as_deref(),
            "Headers",
            &runtime_state,
        )
        .is_err()
    {
        session_request.forbidden().await;
        return Ok(());
    }

    let max_pending_messages = route_match.max_pending_messages;
    let max_pending_bytes = route_match.max_pending_bytes;
    let route_id = route_match.route_id;
    let path_params = route_match.path_params;
    let transport_request = TransportRequest {
        route_id: route_id.clone(),
        path_params: path_params.clone(),
        query: query.clone(),
        headers: headers.clone(),
        body: None,
        body_stream: None,
        request_kind: NativeRequestKind::WebTransport,
        body_kind: NativeBodyKind::None,
    };

    let (request_id, mut response_rx) =
        match dispatch_request_to_dart(transport_request, &runtime_state) {
            Ok(value) => value,
            Err(_) => {
                session_request.forbidden().await;
                return Ok(());
            }
        };

    match response_rx.recv().await {
        Some(PendingResponseMessage::Http(_)) => {
            session_request.forbidden().await;
        }
        Some(PendingResponseMessage::WebSocketAccept {
            headers: response_headers,
        }) => {
            let connection = session_request
                .accept_with_headers(response_headers)
                .await
                .map_err(|error| format!("Failed to accept WebTransport session: {error}"))?;
            handle_web_transport_session(
                connection,
                request_id,
                route_id,
                path_params,
                query,
                headers,
                max_pending_messages,
                max_pending_bytes,
                runtime_state,
            )
            .await;
        }
        _ => {
            session_request.forbidden().await;
        }
    }

    Ok(())
}

async fn handle_web_transport_session(
    connection: WebTransportConnection,
    request_id: i64,
    route_id: String,
    path_params: HashMap<String, String>,
    query: HashMap<String, String>,
    headers: HashMap<String, String>,
    max_pending_messages: usize,
    max_pending_bytes: usize,
    runtime_state: ServerRuntimeState,
) {
    let session_id = NEXT_WEB_TRANSPORT_SESSION_ID.fetch_add(1, Ordering::Relaxed);
    let (command_tx, mut command_rx) = mpsc::unbounded_channel::<WebTransportCommand>();
    {
        let mut sessions = WEB_TRANSPORT_SESSIONS.lock().unwrap();
        sessions.insert(
            session_id,
            WebTransportSessionState {
                server_id: runtime_state.server_id,
                connection: Some(WebTransportConnectionInfo {
                    session_id,
                    request_id,
                    route_id,
                    path_params,
                    query,
                    headers,
                }),
                datagrams: VecDeque::new(),
                streams: VecDeque::new(),
                pending_bytes: 0,
                max_pending_messages,
                max_pending_bytes,
                command_tx,
            },
        );
    }
    notify_transport_event(
        &runtime_state,
        TransportEventKind::WebTransportOpened,
        session_id,
    );

    loop {
        tokio::select! {
            incoming = connection.receive_datagram() => {
                match incoming {
                    Ok(datagram) => {
                        let accepted = push_web_transport_datagram(
                            session_id,
                            WebTransportIncomingDatagram {
                                session_id,
                                body: datagram.payload().to_vec(),
                            },
                        );
                        if !accepted {
                            connection.close(
                                VarInt::from_u32(REALTIME_OVERLOAD_CODE),
                                b"incoming queue limit exceeded",
                            );
                            break;
                        }
                        notify_transport_event(
                            &runtime_state,
                            TransportEventKind::WebTransportDatagramReady,
                            session_id,
                        );
                    }
                    Err(_) => break,
                }
            }
            incoming = connection.accept_uni() => {
                match incoming {
                    Ok(stream) => {
                        register_web_transport_receive_stream(
                            session_id,
                            WebTransportStreamKind::IncomingUnidirectional,
                            stream,
                            None,
                            runtime_state.clone(),
                            true,
                            max_pending_messages,
                            max_pending_bytes,
                        );
                    }
                    Err(_) => break,
                }
            }
            incoming = connection.accept_bi() => {
                match incoming {
                    Ok((send, receive)) => {
                        register_web_transport_receive_stream(
                            session_id,
                            WebTransportStreamKind::IncomingBidirectional,
                            receive,
                            Some(send),
                            runtime_state.clone(),
                            false,
                            max_pending_messages,
                            max_pending_bytes,
                        );
                    }
                    Err(_) => break,
                }
            }
            command = command_rx.recv() => {
                match command {
                    Some(WebTransportCommand::SendDatagram(body)) => {
                        if connection.send_datagram(body).is_err() {
                            break;
                        }
                    }
                    Some(WebTransportCommand::SendStream(body)) => {
                        match connection.open_uni().await {
                            Ok(opening) => match opening.await {
                                Ok(mut stream) => {
                                    if stream.write_all(&body).await.is_err()
                                        || stream.finish().await.is_err()
                                    {
                                        break;
                                    }
                                }
                                Err(_) => break,
                            },
                            Err(_) => break,
                        }
                    }
                    Some(WebTransportCommand::OpenUnidirectional { operation_id }) => {
                        let connection = connection.clone();
                        let runtime_state = runtime_state.clone();
                        tokio::spawn(async move {
                            open_web_transport_unidirectional_stream(
                                connection,
                                session_id,
                                operation_id,
                                runtime_state,
                            ).await;
                        });
                    }
                    Some(WebTransportCommand::OpenBidirectional { operation_id }) => {
                        let connection = connection.clone();
                        let runtime_state = runtime_state.clone();
                        tokio::spawn(async move {
                            open_web_transport_bidirectional_stream(
                                connection,
                                session_id,
                                operation_id,
                                runtime_state,
                            ).await;
                        });
                    }
                    Some(WebTransportCommand::Close { code, reason }) => {
                        let code = code.map(VarInt::from_u32).unwrap_or_else(|| VarInt::from_u32(0));
                        let reason = reason.unwrap_or_default();
                        connection.close(code, reason.as_bytes());
                        break;
                    }
                    None => break,
                }
            }
        }
    }

    let _ = WEB_TRANSPORT_SESSIONS.lock().unwrap().remove(&session_id);
    WEB_TRANSPORT_STREAMS
        .lock()
        .unwrap()
        .retain(|_, stream| stream.info.session_id != session_id);
    notify_transport_event(
        &runtime_state,
        TransportEventKind::WebTransportClosed,
        session_id,
    );
}

fn dispatch_request_to_dart(
    transport_request: TransportRequest,
    runtime_state: &ServerRuntimeState,
) -> Result<(i64, mpsc::UnboundedReceiver<PendingResponseMessage>), Response<Body>> {
    let request_id = NEXT_REQUEST_ID.fetch_add(1, Ordering::Relaxed);
    let (response_tx, response_rx) = mpsc::unbounded_channel::<PendingResponseMessage>();
    {
        let mut pending = PENDING_REQUESTS.lock().unwrap();
        pending.insert(
            request_id,
            PendingRequest {
                server_id: runtime_state.server_id,
                request: Some(transport_request),
                response_tx,
            },
        );
    }

    if !notify_transport_event(runtime_state, TransportEventKind::RequestReady, request_id) {
        let _ = PENDING_REQUESTS.lock().unwrap().remove(&request_id);
        return Err(response(
            StatusCode::INTERNAL_SERVER_ERROR,
            "text/plain; charset=utf-8",
            "No Dart callback registered".to_string(),
        ));
    }

    Ok((request_id, response_rx))
}

fn send_pending_response_message(
    request_id: i64,
    message: PendingResponseMessage,
    remove: bool,
) -> bool {
    let response_tx = {
        let mut pending = PENDING_REQUESTS.lock().unwrap();
        if remove {
            let Some(request) = pending.remove(&request_id) else {
                return false;
            };
            request.response_tx
        } else {
            let Some(request) = pending.get(&request_id) else {
                return false;
            };
            request.response_tx.clone()
        }
    };

    if response_tx.send(message).is_ok() {
        return true;
    }

    if !remove {
        let _ = PENDING_REQUESTS.lock().unwrap().remove(&request_id);
    }
    false
}

fn notify_transport_event(
    runtime_state: &ServerRuntimeState,
    event_kind: TransportEventKind,
    event_id: i64,
) -> bool {
    if !SERVER_STATES
        .lock()
        .unwrap()
        .contains_key(&runtime_state.server_id)
    {
        return false;
    }

    (runtime_state.callback)(event_kind as i32, event_id);
    true
}

fn wants_web_socket_upgrade(headers: &HeaderMap) -> bool {
    headers
        .get(header::UPGRADE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.eq_ignore_ascii_case("websocket"))
}

fn append_headers(target: &mut HeaderMap, headers: &[(String, String)]) {
    for (name, value) in headers {
        let Ok(header_name) = HeaderName::try_from(name.as_str()) else {
            continue;
        };
        let Ok(header_value) = HeaderValue::from_str(value) else {
            continue;
        };
        target.append(header_name, header_value);
    }
}

fn response_body_with_headers(
    status: StatusCode,
    content_type: &str,
    headers: &[(String, String)],
    body: Body,
) -> Response<Body> {
    let mut builder = Response::builder().status(status);
    builder = builder.header(header::CONTENT_TYPE, content_type);
    for (name, value) in headers {
        builder = builder.header(name, value);
    }
    builder
        .body(body)
        .unwrap_or_else(|_| Response::new(Body::from("Internal Server Error")))
}

fn push_web_socket_message(session_id: i64, message: WebSocketIncomingMessage) -> bool {
    let mut sessions = WEB_SOCKET_SESSIONS.lock().unwrap();
    if let Some(session) = sessions.get_mut(&session_id) {
        let next_bytes = session.pending_bytes.saturating_add(message.body.len());
        if session.messages.len() >= session.max_pending_messages
            || next_bytes > session.max_pending_bytes
        {
            return false;
        }
        session.pending_bytes = next_bytes;
        session.messages.push_back(message);
        return true;
    }
    false
}

fn push_web_transport_datagram(session_id: i64, datagram: WebTransportIncomingDatagram) -> bool {
    let mut sessions = WEB_TRANSPORT_SESSIONS.lock().unwrap();
    if let Some(session) = sessions.get_mut(&session_id) {
        let next_bytes = session.pending_bytes.saturating_add(datagram.body.len());
        if session
            .datagrams
            .len()
            .saturating_add(session.streams.len())
            >= session.max_pending_messages
            || next_bytes > session.max_pending_bytes
        {
            return false;
        }
        session.pending_bytes = next_bytes;
        session.datagrams.push_back(datagram);
        return true;
    }
    false
}

fn push_web_transport_stream(session_id: i64, stream: WebTransportIncomingStream) -> bool {
    let mut sessions = WEB_TRANSPORT_SESSIONS.lock().unwrap();
    if let Some(session) = sessions.get_mut(&session_id) {
        let next_bytes = session.pending_bytes.saturating_add(stream.body.len());
        if session
            .datagrams
            .len()
            .saturating_add(session.streams.len())
            >= session.max_pending_messages
            || next_bytes > session.max_pending_bytes
        {
            return false;
        }
        session.pending_bytes = next_bytes;
        session.streams.push_back(stream);
        return true;
    }
    false
}

fn register_web_transport_receive_stream(
    session_id: i64,
    kind: WebTransportStreamKind,
    receive: wtransport::stream::RecvStream,
    send: Option<wtransport::stream::SendStream>,
    runtime_state: ServerRuntimeState,
    collect_legacy_payload: bool,
    max_pending_messages: usize,
    max_pending_bytes: usize,
) {
    let stream_id = NEXT_WEB_TRANSPORT_STREAM_HANDLE_ID.fetch_add(1, Ordering::Relaxed);
    let protocol_id = receive.id().into_u64() as i64;
    let info = WebTransportStreamInfo {
        session_id,
        stream_id,
        protocol_id,
        kind,
    };
    let (stop_tx, stop_rx) = mpsc::unbounded_channel();
    let send_tx =
        send.map(|send| spawn_web_transport_send_actor(info, send, runtime_state.clone()));
    let send_closed = send_tx.is_none();
    WEB_TRANSPORT_STREAMS.lock().unwrap().insert(
        stream_id,
        WebTransportStreamState {
            info,
            runtime_state: runtime_state.clone(),
            chunks: VecDeque::new(),
            pending_bytes: 0,
            max_pending_messages,
            max_pending_bytes,
            terminal: None,
            send_tx,
            stop_tx: Some(stop_tx),
            send_closed,
            receive_closed: false,
        },
    );
    WEB_TRANSPORT_OPENED_STREAMS
        .lock()
        .unwrap()
        .insert(stream_id, info);
    notify_transport_event(
        &runtime_state,
        TransportEventKind::WebTransportPersistentStreamOpened,
        stream_id,
    );
    tokio::spawn(read_web_transport_stream_chunks(
        info,
        receive,
        stop_rx,
        runtime_state,
        collect_legacy_payload,
        max_pending_bytes,
    ));
}

async fn open_web_transport_unidirectional_stream(
    connection: WebTransportConnection,
    session_id: i64,
    operation_id: i64,
    runtime_state: ServerRuntimeState,
) {
    let result = async {
        let opening = connection
            .open_uni()
            .await
            .map_err(|error| error.to_string())?;
        opening.await.map_err(|error| error.to_string())
    }
    .await;
    match result {
        Ok(send) => register_opened_web_transport_send_stream(
            session_id,
            operation_id,
            WebTransportStreamKind::OutgoingUnidirectional,
            WebTransportOperationKind::OpenUnidirectional,
            send,
            None,
            runtime_state,
        ),
        Err(error) => complete_web_transport_open_error(
            session_id,
            operation_id,
            WebTransportOperationKind::OpenUnidirectional,
            error,
            &runtime_state,
        ),
    }
}

async fn open_web_transport_bidirectional_stream(
    connection: WebTransportConnection,
    session_id: i64,
    operation_id: i64,
    runtime_state: ServerRuntimeState,
) {
    let result = async {
        let opening = connection
            .open_bi()
            .await
            .map_err(|error| error.to_string())?;
        opening.await.map_err(|error| error.to_string())
    }
    .await;
    match result {
        Ok((send, receive)) => register_opened_web_transport_send_stream(
            session_id,
            operation_id,
            WebTransportStreamKind::OutgoingBidirectional,
            WebTransportOperationKind::OpenBidirectional,
            send,
            Some(receive),
            runtime_state,
        ),
        Err(error) => complete_web_transport_open_error(
            session_id,
            operation_id,
            WebTransportOperationKind::OpenBidirectional,
            error,
            &runtime_state,
        ),
    }
}

fn register_opened_web_transport_send_stream(
    session_id: i64,
    operation_id: i64,
    kind: WebTransportStreamKind,
    operation_kind: WebTransportOperationKind,
    send: wtransport::stream::SendStream,
    receive: Option<wtransport::stream::RecvStream>,
    runtime_state: ServerRuntimeState,
) {
    let (max_pending_messages, max_pending_bytes) = web_transport_session_limits(session_id);
    let stream_id = NEXT_WEB_TRANSPORT_STREAM_HANDLE_ID.fetch_add(1, Ordering::Relaxed);
    let protocol_id = send.id().into_u64() as i64;
    let info = WebTransportStreamInfo {
        session_id,
        stream_id,
        protocol_id,
        kind,
    };
    let send_tx = spawn_web_transport_send_actor(info, send, runtime_state.clone());
    let (stop_tx, stop_rx) = if receive.is_some() {
        let (tx, rx) = mpsc::unbounded_channel();
        (Some(tx), Some(rx))
    } else {
        (None, None)
    };
    WEB_TRANSPORT_STREAMS.lock().unwrap().insert(
        stream_id,
        WebTransportStreamState {
            info,
            runtime_state: runtime_state.clone(),
            chunks: VecDeque::new(),
            pending_bytes: 0,
            max_pending_messages,
            max_pending_bytes,
            terminal: None,
            send_tx: Some(send_tx),
            stop_tx,
            send_closed: false,
            receive_closed: receive.is_none(),
        },
    );
    push_web_transport_operation(
        WebTransportOperationResult {
            operation_id,
            session_id,
            stream_id,
            protocol_id,
            kind: operation_kind,
            error: None,
        },
        &runtime_state,
    );
    if let (Some(receive), Some(stop_rx)) = (receive, stop_rx) {
        tokio::spawn(read_web_transport_stream_chunks(
            info,
            receive,
            stop_rx,
            runtime_state,
            false,
            max_pending_bytes,
        ));
    }
}

fn complete_web_transport_open_error(
    session_id: i64,
    operation_id: i64,
    kind: WebTransportOperationKind,
    error: String,
    runtime_state: &ServerRuntimeState,
) {
    push_web_transport_operation(
        WebTransportOperationResult {
            operation_id,
            session_id,
            stream_id: 0,
            protocol_id: 0,
            kind,
            error: Some(error),
        },
        runtime_state,
    );
}

fn spawn_web_transport_send_actor(
    info: WebTransportStreamInfo,
    mut send: wtransport::stream::SendStream,
    runtime_state: ServerRuntimeState,
) -> mpsc::Sender<WebTransportStreamCommand> {
    let (tx, mut rx) = mpsc::channel(8);
    tokio::spawn(async move {
        while let Some(command) = rx.recv().await {
            let (operation_id, kind, result, terminal) = match command {
                WebTransportStreamCommand::Write { operation_id, body } => (
                    operation_id,
                    WebTransportOperationKind::Write,
                    send.write_all(&body)
                        .await
                        .map_err(|error| error.to_string()),
                    false,
                ),
                WebTransportStreamCommand::Finish { operation_id } => (
                    operation_id,
                    WebTransportOperationKind::Finish,
                    send.finish().await.map_err(|error| error.to_string()),
                    true,
                ),
                WebTransportStreamCommand::Reset {
                    operation_id,
                    error_code,
                } => (
                    operation_id,
                    WebTransportOperationKind::Reset,
                    send.reset(VarInt::from_u32(error_code))
                        .map_err(|error| error.to_string()),
                    true,
                ),
            };
            push_web_transport_operation(
                WebTransportOperationResult {
                    operation_id,
                    session_id: info.session_id,
                    stream_id: info.stream_id,
                    protocol_id: info.protocol_id,
                    kind,
                    error: result.err(),
                },
                &runtime_state,
            );
            if terminal {
                if let Some(stream) = WEB_TRANSPORT_STREAMS
                    .lock()
                    .unwrap()
                    .get_mut(&info.stream_id)
                {
                    stream.send_closed = true;
                    stream.send_tx = None;
                }
                remove_web_transport_stream_if_complete(info.stream_id);
                break;
            }
        }
    });
    tx
}

async fn read_web_transport_stream_chunks(
    info: WebTransportStreamInfo,
    mut receive: wtransport::stream::RecvStream,
    mut stop_rx: mpsc::UnboundedReceiver<u32>,
    runtime_state: ServerRuntimeState,
    collect_legacy_payload: bool,
    max_pending_bytes: usize,
) {
    let mut legacy_payload = collect_legacy_payload.then(Vec::new);
    let mut buffer = [0u8; 16 * 1024];
    let terminal = loop {
        tokio::select! {
            stop = stop_rx.recv() => {
                let error_code = stop.unwrap_or_default();
                receive.stop(VarInt::from_u32(error_code));
                break WebTransportStreamTerminal { error_code: Some(error_code), error: "receive stopped locally".to_string() };
            }
            result = receive.read(&mut buffer) => {
                match result {
                    Ok(Some(bytes_read)) => {
                        let body = buffer[..bytes_read].to_vec();
                        if let Some(payload) = legacy_payload.as_mut() {
                            if payload.len().saturating_add(body.len()) > max_pending_bytes {
                                receive.stop(VarInt::from_u32(REALTIME_OVERLOAD_CODE));
                                break WebTransportStreamTerminal {
                                    error_code: Some(REALTIME_OVERLOAD_CODE),
                                    error: "incoming legacy stream exceeded its byte limit".to_string(),
                                };
                            }
                            payload.extend_from_slice(&body);
                        }
                        if let Some(stream) = WEB_TRANSPORT_STREAMS.lock().unwrap().get_mut(&info.stream_id) {
                            let next_bytes = stream.pending_bytes.saturating_add(body.len());
                            if stream.chunks.len() >= stream.max_pending_messages
                                || next_bytes > stream.max_pending_bytes
                            {
                                receive.stop(VarInt::from_u32(REALTIME_OVERLOAD_CODE));
                                break WebTransportStreamTerminal {
                                    error_code: Some(REALTIME_OVERLOAD_CODE),
                                    error: "incoming stream queue limit exceeded".to_string(),
                                };
                            }
                            stream.pending_bytes = next_bytes;
                            stream.chunks.push_back(body);
                        } else {
                            return;
                        }
                        notify_transport_event(&runtime_state, TransportEventKind::WebTransportStreamChunkReady, info.stream_id);
                    }
                    Ok(None) => break WebTransportStreamTerminal { error_code: None, error: String::new() },
                    Err(error) => {
                        let error_code = match error {
                            wtransport::error::StreamReadError::Reset(code) => Some(code.into_inner() as u32),
                            _ => None,
                        };
                        break WebTransportStreamTerminal { error_code, error: error.to_string() };
                    }
                }
            }
        }
    };
    if let Some(body) = legacy_payload {
        let accepted = push_web_transport_stream(
            info.session_id,
            WebTransportIncomingStream {
                session_id: info.session_id,
                body,
            },
        );
        if accepted {
            notify_transport_event(
                &runtime_state,
                TransportEventKind::WebTransportStreamReady,
                info.session_id,
            );
        }
    }
    if let Some(stream) = WEB_TRANSPORT_STREAMS
        .lock()
        .unwrap()
        .get_mut(&info.stream_id)
    {
        stream.terminal = Some(terminal);
        stream.stop_tx = None;
        stream.receive_closed = true;
    }
    notify_transport_event(
        &runtime_state,
        TransportEventKind::WebTransportStreamFinished,
        info.stream_id,
    );
}

fn web_transport_session_limits(session_id: i64) -> (usize, usize) {
    WEB_TRANSPORT_SESSIONS
        .lock()
        .unwrap()
        .get(&session_id)
        .map(|session| (session.max_pending_messages, session.max_pending_bytes))
        .unwrap_or((
            DEFAULT_REALTIME_MAX_PENDING_MESSAGES,
            DEFAULT_REALTIME_MAX_PENDING_BYTES,
        ))
}

fn submit_web_transport_session_operation(
    session_id: i64,
    command: impl FnOnce(i64) -> WebTransportCommand,
) -> i64 {
    let operation_id = NEXT_WEB_TRANSPORT_OPERATION_ID.fetch_add(1, Ordering::Relaxed);
    let sessions = WEB_TRANSPORT_SESSIONS.lock().unwrap();
    let Some(session) = sessions.get(&session_id) else {
        return 0;
    };
    if session.command_tx.send(command(operation_id)).is_err() {
        0
    } else {
        operation_id
    }
}

fn submit_web_transport_send_operation(
    stream_id: i64,
    command: impl FnOnce(i64) -> WebTransportStreamCommand,
) -> i64 {
    let operation_id = NEXT_WEB_TRANSPORT_OPERATION_ID.fetch_add(1, Ordering::Relaxed);
    let streams = WEB_TRANSPORT_STREAMS.lock().unwrap();
    let Some(send_tx) = streams
        .get(&stream_id)
        .and_then(|stream| stream.send_tx.as_ref())
    else {
        return 0;
    };
    match send_tx.try_send(command(operation_id)) {
        Ok(()) => operation_id,
        Err(_) => 0,
    }
}

fn push_web_transport_operation(
    operation: WebTransportOperationResult,
    runtime_state: &ServerRuntimeState,
) {
    let operation_id = operation.operation_id;
    WEB_TRANSPORT_OPERATIONS
        .lock()
        .unwrap()
        .insert(operation_id, operation);
    notify_transport_event(
        runtime_state,
        TransportEventKind::WebTransportOperationReady,
        operation_id,
    );
}

fn remove_web_transport_stream_if_complete(stream_id: i64) {
    let mut streams = WEB_TRANSPORT_STREAMS.lock().unwrap();
    let remove = streams.get(&stream_id).is_some_and(|stream| {
        stream.send_closed
            && stream.receive_closed
            && stream.terminal.is_none()
            && stream.chunks.is_empty()
    });
    if remove {
        streams.remove(&stream_id);
    }
}

fn resolve_bind_address(host: &str, port: u16) -> Result<SocketAddr, String> {
    let ip = host
        .parse::<IpAddr>()
        .map_err(|error| format!("Invalid bind host '{host}': {error}"))?;
    Ok(SocketAddr::new(ip, port))
}

fn split_web_transport_path(value: &str) -> (String, Option<&str>) {
    match value.split_once('?') {
        Some((path, query)) => (path.to_string(), Some(query)),
        None => (value.to_string(), None),
    }
}

fn collect_web_transport_headers(headers: HashMap<String, String>) -> HashMap<String, String> {
    headers
        .into_iter()
        .map(|(name, value)| (name.to_ascii_lowercase(), value))
        .collect()
}

async fn try_send_web_socket_close(
    socket: &mut WebSocket,
    code: Option<u16>,
    reason: Option<String>,
) -> Result<(), axum::Error> {
    let frame = match (code, reason) {
        (None, None) => None,
        (code, reason) => Some(CloseFrame {
            code: code.unwrap_or(close_code::NORMAL),
            reason: reason.unwrap_or_default().into(),
        }),
    };

    socket.send(Message::Close(frame)).await
}

fn compile_manifest(routes_json: &str) -> Result<CompiledManifest, String> {
    let manifest: RouteManifest =
        serde_json::from_str(routes_json).map_err(|error| error.to_string())?;
    let schemas = compile_schemas(manifest.schemas)?;
    let routes = manifest
        .routes
        .into_iter()
        .map(|route| compile_route(route, &schemas))
        .collect::<Result<Vec<_>, _>>()?;

    Ok(CompiledManifest { routes, schemas })
}

fn compile_cors_layer(middlewares_json: &str) -> Result<Option<CorsLayer>, String> {
    let manifest: MiddlewareManifest =
        serde_json::from_str(middlewares_json).map_err(|error| error.to_string())?;

    for middleware in manifest.middlewares {
        if middleware.name != "cors" {
            continue;
        }

        let configuration: CorsMiddlewareConfiguration =
            serde_json::from_value(middleware.configuration).map_err(|error| error.to_string())?;
        return Ok(Some(cors_layer(configuration)?));
    }

    Ok(None)
}

fn cors_layer(configuration: CorsMiddlewareConfiguration) -> Result<CorsLayer, String> {
    let mut layer = CorsLayer::new().allow_methods([
        Method::GET,
        Method::POST,
        Method::PUT,
        Method::PATCH,
        Method::DELETE,
        Method::HEAD,
        Method::OPTIONS,
    ]);

    layer = if configuration.allow_origins.is_empty()
        || configuration
            .allow_origins
            .iter()
            .any(|origin| origin == "*")
    {
        layer.allow_origin(Any)
    } else {
        let origins = configuration
            .allow_origins
            .iter()
            .map(|origin| {
                HeaderValue::from_str(origin)
                    .map_err(|error| format!("Invalid CORS origin '{origin}': {error}"))
            })
            .collect::<Result<Vec<_>, _>>()?;
        layer.allow_origin(origins)
    };

    layer = if configuration.allow_headers.is_empty()
        || configuration
            .allow_headers
            .iter()
            .any(|header| header == "*")
    {
        layer.allow_headers(Any)
    } else {
        let headers = configuration
            .allow_headers
            .iter()
            .map(|header| {
                HeaderName::try_from(header.as_str())
                    .map_err(|error| format!("Invalid CORS header '{header}': {error}"))
            })
            .collect::<Result<Vec<_>, _>>()?;
        layer.allow_headers(headers)
    };

    Ok(layer)
}

fn compile_schemas(
    manifest_schemas: HashMap<String, serde_json::Value>,
) -> Result<HashMap<String, jsonschema::Validator>, String> {
    let schema_ids = manifest_schemas.keys().cloned().collect::<Vec<_>>();
    let registry_schema = schema_registry_document(manifest_schemas);
    let registry = jsonschema::Registry::new()
        .add(SCHEMA_REGISTRY_URI, registry_schema)
        .map_err(|error| format!("Invalid schema registry URI: {error}"))?
        .prepare()
        .map_err(|error| format!("Invalid schema registry: {error}"))?;
    let mut schemas = HashMap::with_capacity(schema_ids.len());

    for id in schema_ids {
        let schema = serde_json::json!({
            "$ref": format!("{SCHEMA_REGISTRY_URI}#/components/schemas/{id}"),
        });
        let validator = jsonschema::options()
            .with_registry(&registry)
            .build(&schema)
            .map_err(|error| format!("Invalid schema '{id}': {error}"))?;
        schemas.insert(id, validator);
    }

    Ok(schemas)
}

fn schema_registry_document(manifest_schemas: HashMap<String, serde_json::Value>) -> Value {
    Value::Object(
        [(
            "components".to_string(),
            Value::Object(
                [(
                    "schemas".to_string(),
                    Value::Object(
                        manifest_schemas
                            .into_iter()
                            .map(|(id, schema)| (id, strip_schema_ids(schema)))
                            .collect(),
                    ),
                )]
                .into_iter()
                .collect(),
            ),
        )]
        .into_iter()
        .collect(),
    )
}

fn strip_schema_ids(value: Value) -> Value {
    match value {
        Value::Array(values) => Value::Array(values.into_iter().map(strip_schema_ids).collect()),
        Value::Object(mut object) => {
            object.remove("$id");
            Value::Object(
                object
                    .into_iter()
                    .map(|(key, value)| (key, strip_schema_ids(value)))
                    .collect(),
            )
        }
        value => value,
    }
}

fn compile_route(
    route: RouteManifestEntry,
    schemas: &HashMap<String, jsonschema::Validator>,
) -> Result<CompiledRoute, String> {
    if route.max_pending_messages == 0 {
        return Err(format!(
            "Route '{}' maxPendingMessages must be at least 1",
            route.route_id
        ));
    }
    if route.max_pending_bytes == 0 {
        return Err(format!(
            "Route '{}' maxPendingBytes must be at least 1",
            route.route_id
        ));
    }
    ensure_schema_exists(schemas, route.params_schema_id.as_deref())?;
    ensure_schema_exists(schemas, route.query_schema_id.as_deref())?;
    ensure_schema_exists(schemas, route.headers_schema_id.as_deref())?;
    ensure_schema_exists(
        schemas,
        route
            .request_body
            .as_ref()
            .and_then(|request_body| request_body.schema_id.as_deref()),
    )?;

    let request_body = match route.kind {
        RouteTransportKind::Http | RouteTransportKind::NativeHttp => {
            route
                .request_body
                .map(|request_body| RequestBodyValidation {
                    kind: body_kind(&request_body.content_type),
                    content_type: request_body.content_type,
                    schema_id: request_body.schema_id,
                    streaming: request_body.streaming,
                })
        }
        RouteTransportKind::WebSocket | RouteTransportKind::WebTransport => None,
    };
    let handler_path_segments = route.handler_path_segments.map(compile_route_segments);
    let native_handler = match route.kind {
        RouteTransportKind::NativeHttp => {
            let handle = route.native_handle.ok_or_else(|| {
                format!("Native route '{}' is missing nativeHandle", route.route_id)
            })?;
            let handler_address = route.native_handler_address.ok_or_else(|| {
                format!(
                    "Native route '{}' is missing nativeHandlerAddress",
                    route.route_id
                )
            })?;
            let free_response_address = route.native_free_response_address.ok_or_else(|| {
                format!(
                    "Native route '{}' is missing nativeFreeResponseAddress",
                    route.route_id
                )
            })?;
            Some(CompiledNativeHttpHandler {
                handle,
                handler: unsafe {
                    std::mem::transmute::<usize, NativeHttpHandler>(handler_address)
                },
                free_response: unsafe {
                    std::mem::transmute::<usize, NativeHttpFreeResponse>(free_response_address)
                },
                handler_path_segments,
            })
        }
        _ => None,
    };

    Ok(CompiledRoute {
        kind: route.kind,
        route_id: route.route_id,
        method: route.method,
        path_segments: compile_route_segments(route.path_segments),
        params_schema_id: route.params_schema_id,
        query_schema_id: route.query_schema_id,
        headers_schema_id: route.headers_schema_id,
        request_body,
        native_handler,
        max_pending_messages: route.max_pending_messages,
        max_pending_bytes: route.max_pending_bytes,
    })
}

const fn default_realtime_max_pending_messages() -> usize {
    DEFAULT_REALTIME_MAX_PENDING_MESSAGES
}

const fn default_realtime_max_pending_bytes() -> usize {
    DEFAULT_REALTIME_MAX_PENDING_BYTES
}

fn compile_route_segments(segments: Vec<RouteSegmentManifest>) -> Vec<CompiledRouteSegment> {
    segments
        .into_iter()
        .map(|segment| {
            if segment.is_wildcard {
                CompiledRouteSegment::Wildcard(segment.value)
            } else if segment.is_parameter {
                CompiledRouteSegment::Parameter(segment.value)
            } else {
                CompiledRouteSegment::Literal(segment.value)
            }
        })
        .collect()
}

fn ensure_schema_exists(
    schemas: &HashMap<String, jsonschema::Validator>,
    schema_id: Option<&str>,
) -> Result<(), String> {
    let Some(schema_id) = schema_id else {
        return Ok(());
    };

    if schemas.contains_key(schema_id) {
        Ok(())
    } else {
        Err(format!("Route references missing schema '{schema_id}'"))
    }
}

fn build_runtime(worker_count: usize) -> Result<tokio::runtime::Runtime, std::io::Error> {
    if worker_count == 1 {
        return tokio::runtime::Builder::new_current_thread()
            .enable_io()
            .enable_time()
            .build();
    }

    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(worker_count)
        .max_blocking_threads(worker_count)
        .thread_stack_size(1024 * 1024)
        .enable_io()
        .enable_time()
        .build()
}

impl NativeTransportRequestHandle {
    fn from_transport_request(request: TransportRequest) -> Self {
        let route_id = OwnedBytes::from_vec(request.route_id.into_bytes());
        let path_params = owned_pairs_from_map(request.path_params);
        let path_param_pairs = native_pairs_from_owned(&path_params);
        let query = owned_pairs_from_map(request.query);
        let query_pairs = native_pairs_from_owned(&query);
        let headers = owned_pairs_from_map(request.headers);
        let header_pairs = native_pairs_from_owned(&headers);
        let body = request.body.map(OwnedBytes::from_vec);
        let body_stream = request.body_stream;

        let native_request = NativeTransportRequest {
            route_id: route_id.as_native(),
            path_param_count: path_param_pairs.len() as isize,
            path_params: boxed_pairs_ptr(&path_param_pairs),
            query_count: query_pairs.len() as isize,
            query: boxed_pairs_ptr(&query_pairs),
            header_count: header_pairs.len() as isize,
            headers: boxed_pairs_ptr(&header_pairs),
            body: body
                .as_ref()
                .map(OwnedBytes::as_native)
                .unwrap_or_else(NativeBytes::empty),
            request_kind: request.request_kind as u8,
            body_kind: request.body_kind as u8,
        };

        Self {
            request: native_request,
            route_id,
            path_params,
            path_param_pairs,
            query,
            query_pairs,
            headers,
            header_pairs,
            body,
            body_stream,
        }
    }
}

impl NativeWebSocketConnectionHandle {
    fn from_connection(connection: WebSocketConnection) -> Self {
        let route_id = OwnedBytes::from_string(connection.route_id);
        let path_params = owned_pairs_from_map(connection.path_params);
        let path_param_pairs = native_pairs_from_owned(&path_params);
        let query = owned_pairs_from_map(connection.query);
        let query_pairs = native_pairs_from_owned(&query);
        let headers = owned_pairs_from_map(connection.headers);
        let header_pairs = native_pairs_from_owned(&headers);

        let native_connection = NativeWebSocketConnection {
            session_id: connection.session_id,
            request_id: connection.request_id,
            route_id: route_id.as_native(),
            path_param_count: path_param_pairs.len() as isize,
            path_params: boxed_pairs_ptr(&path_param_pairs),
            query_count: query_pairs.len() as isize,
            query: boxed_pairs_ptr(&query_pairs),
            header_count: header_pairs.len() as isize,
            headers: boxed_pairs_ptr(&header_pairs),
        };

        Self {
            connection: native_connection,
            route_id,
            path_params,
            path_param_pairs,
            query,
            query_pairs,
            headers,
            header_pairs,
        }
    }
}

impl NativeWebSocketMessageHandle {
    fn from_message(message: WebSocketIncomingMessage) -> Self {
        let body = OwnedBytes::from_vec(message.body);
        let native_message = NativeWebSocketMessage {
            session_id: message.session_id,
            kind: message.kind as u8,
            body: body.as_native(),
        };

        Self {
            message: native_message,
            body,
        }
    }
}

impl NativeWebTransportConnectionHandle {
    fn from_connection(connection: WebTransportConnectionInfo) -> Self {
        let route_id = OwnedBytes::from_string(connection.route_id);
        let path_params = owned_pairs_from_map(connection.path_params);
        let path_param_pairs = native_pairs_from_owned(&path_params);
        let query = owned_pairs_from_map(connection.query);
        let query_pairs = native_pairs_from_owned(&query);
        let headers = owned_pairs_from_map(connection.headers);
        let header_pairs = native_pairs_from_owned(&headers);

        let native_connection = NativeWebTransportConnection {
            session_id: connection.session_id,
            request_id: connection.request_id,
            route_id: route_id.as_native(),
            path_param_count: path_param_pairs.len() as isize,
            path_params: boxed_pairs_ptr(&path_param_pairs),
            query_count: query_pairs.len() as isize,
            query: boxed_pairs_ptr(&query_pairs),
            header_count: header_pairs.len() as isize,
            headers: boxed_pairs_ptr(&header_pairs),
        };

        Self {
            connection: native_connection,
            route_id,
            path_params,
            path_param_pairs,
            query,
            query_pairs,
            headers,
            header_pairs,
        }
    }
}

impl NativeWebTransportDatagramHandle {
    fn from_datagram(datagram: WebTransportIncomingDatagram) -> Self {
        let body = OwnedBytes::from_vec(datagram.body);
        let native_datagram = NativeWebTransportDatagram {
            session_id: datagram.session_id,
            body: body.as_native(),
        };

        Self {
            datagram: native_datagram,
            body,
        }
    }
}

impl NativeWebTransportStreamHandle {
    fn from_stream(stream: WebTransportIncomingStream) -> Self {
        let body = OwnedBytes::from_vec(stream.body);
        let native_stream = NativeWebTransportStream {
            session_id: stream.session_id,
            body: body.as_native(),
        };

        Self {
            stream: native_stream,
            body,
        }
    }
}

impl NativeWebTransportStreamChunkHandle {
    fn new(stream_id: i64, body: Vec<u8>) -> Self {
        let body = OwnedBytes::from_vec(body);
        let chunk = NativeWebTransportStreamChunk {
            stream_id,
            body: body.as_native(),
        };
        Self { chunk, body }
    }
}

impl NativeWebTransportStreamTerminalHandle {
    fn new(stream_id: i64, terminal: WebTransportStreamTerminal) -> Self {
        let error = OwnedBytes::from_vec(terminal.error.into_bytes());
        let native_terminal = NativeWebTransportStreamTerminal {
            stream_id,
            error_code: terminal.error_code.map(i64::from).unwrap_or(-1),
            error: error.as_native(),
        };
        Self {
            terminal: native_terminal,
            error,
        }
    }
}

impl NativeWebTransportOperationHandle {
    fn new(operation: WebTransportOperationResult) -> Self {
        let error = OwnedBytes::from_vec(operation.error.clone().unwrap_or_default().into_bytes());
        let native_operation = NativeWebTransportOperation {
            operation_id: operation.operation_id,
            session_id: operation.session_id,
            stream_id: operation.stream_id,
            protocol_id: operation.protocol_id,
            kind: operation.kind as u8,
            succeeded: operation.error.is_none(),
            error: error.as_native(),
        };
        Self {
            operation: native_operation,
            error,
        }
    }
}

impl OwnedMultipartField {
    fn new(name: String, value: String) -> Self {
        Self {
            name: OwnedBytes::from_string(name),
            value: OwnedBytes::from_string(value),
        }
    }

    fn as_native(&self) -> NativeMultipartField {
        NativeMultipartField {
            name: self.name.as_native(),
            value: self.value.as_native(),
        }
    }
}

impl OwnedMultipartFile {
    fn new(
        field_name: String,
        filename: Option<String>,
        content_type: Option<String>,
        body_ptr: *const u8,
        body_start: usize,
        body_len: usize,
    ) -> Self {
        let body = if body_len == 0 {
            NativeBytes::empty()
        } else {
            NativeBytes {
                ptr: unsafe { body_ptr.add(body_start) },
                len: body_len as isize,
            }
        };

        Self {
            field_name: OwnedBytes::from_string(field_name),
            filename: filename.map(OwnedBytes::from_string),
            content_type: content_type.map(OwnedBytes::from_string),
            body,
        }
    }

    fn as_native(&self) -> NativeMultipartFile {
        NativeMultipartFile {
            field_name: self.field_name.as_native(),
            filename: self
                .filename
                .as_ref()
                .map(OwnedBytes::as_native)
                .unwrap_or_else(NativeBytes::empty),
            content_type: self
                .content_type
                .as_ref()
                .map(OwnedBytes::as_native)
                .unwrap_or_else(NativeBytes::empty),
            body: self.body,
        }
    }
}

impl NativeMultipartFormHandle {
    fn from_parsed_form(form: ParsedMultipartForm, body_ptr: *const u8) -> Self {
        let fields = form
            .fields
            .into_iter()
            .map(|field| OwnedMultipartField::new(field.name, field.value))
            .collect::<Vec<_>>();
        let field_storage = fields
            .iter()
            .map(OwnedMultipartField::as_native)
            .collect::<Vec<_>>()
            .into_boxed_slice();
        let files = form
            .files
            .into_iter()
            .map(|file| {
                OwnedMultipartFile::new(
                    file.field_name,
                    file.filename,
                    file.content_type,
                    body_ptr,
                    file.body_start,
                    file.body_len,
                )
            })
            .collect::<Vec<_>>();
        let file_storage = files
            .iter()
            .map(OwnedMultipartFile::as_native)
            .collect::<Vec<_>>()
            .into_boxed_slice();

        let native_form = NativeMultipartForm {
            field_count: field_storage.len() as isize,
            fields: boxed_ptr(&field_storage),
            file_count: file_storage.len() as isize,
            files: boxed_ptr(&file_storage),
        };

        Self {
            form: native_form,
            fields,
            field_storage,
            files,
            file_storage,
        }
    }
}

fn match_route(
    runtime_state: &ServerRuntimeState,
    method: &str,
    path: &str,
    requested_kind: RouteTransportKind,
) -> Option<NativeRouteMatch> {
    let request_segments = path_segments(path);

    for route in runtime_state.routes.iter() {
        if !route_kind_matches(route.kind, requested_kind) {
            continue;
        }
        if route.method.as_str() != method {
            continue;
        }
        if !route_segment_count_matches(&route.path_segments, request_segments.len()) {
            continue;
        }

        let mut path_params = HashMap::new();
        let mut matched = true;

        for (index, route_segment) in route.path_segments.iter().enumerate() {
            match route_segment {
                CompiledRouteSegment::Literal(literal)
                    if request_segments.get(index) == Some(&literal.as_str()) => {}
                CompiledRouteSegment::Literal(_) => {
                    matched = false;
                    break;
                }
                CompiledRouteSegment::Parameter(name) => {
                    let Some(request_segment) = request_segments.get(index) else {
                        matched = false;
                        break;
                    };
                    path_params.insert(name.clone(), (*request_segment).to_string());
                }
                CompiledRouteSegment::Wildcard(name) => {
                    path_params.insert(name.clone(), request_segments[index..].join("/"));
                    break;
                }
            }
        }

        if matched {
            return Some(NativeRouteMatch {
                kind: route.kind,
                route_id: route.route_id.clone(),
                path_params,
                params_schema_id: route.params_schema_id.clone(),
                query_schema_id: route.query_schema_id.clone(),
                headers_schema_id: route.headers_schema_id.clone(),
                request_body: route.request_body.clone(),
                native_handler: route.native_handler.clone(),
                max_pending_messages: route.max_pending_messages,
                max_pending_bytes: route.max_pending_bytes,
            });
        }
    }

    None
}

fn route_segment_count_matches(
    route_segments: &[CompiledRouteSegment],
    request_segment_count: usize,
) -> bool {
    match route_segments.last() {
        Some(CompiledRouteSegment::Wildcard(_)) => {
            request_segment_count >= route_segments.len() - 1
        }
        _ => route_segments.len() == request_segment_count,
    }
}

fn route_kind_matches(route_kind: RouteTransportKind, requested_kind: RouteTransportKind) -> bool {
    match requested_kind {
        RouteTransportKind::Http => {
            matches!(
                route_kind,
                RouteTransportKind::Http | RouteTransportKind::NativeHttp
            )
        }
        RouteTransportKind::NativeHttp => false,
        RouteTransportKind::WebSocket => route_kind == RouteTransportKind::WebSocket,
        RouteTransportKind::WebTransport => route_kind == RouteTransportKind::WebTransport,
    }
}

fn validate_and_read_body(
    headers: &HeaderMap,
    body: Bytes,
    request_body: Option<&RequestBodyValidation>,
) -> Result<ValidatedBody, Response<Body>> {
    if body.is_empty() {
        return Ok(ValidatedBody::none());
    }

    if let Some(request_body) = request_body {
        let actual_content_type = headers
            .get(header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok());

        if !content_type_matches(actual_content_type, &request_body.content_type) {
            return Err(response(
                StatusCode::UNSUPPORTED_MEDIA_TYPE,
                "text/plain; charset=utf-8",
                format!("Expected {}", request_body.content_type),
            ));
        }

        return match request_body.kind {
            RequestBodyKind::Json => parse_json_body(body),
            RequestBodyKind::Multipart => Ok(ValidatedBody {
                bytes: Some(body.to_vec()),
                kind: NativeBodyKind::Multipart,
                json: None,
            }),
            RequestBodyKind::Text | RequestBodyKind::Other => {
                parse_utf8_body(body, NativeBodyKind::Text)
            }
        };
    }

    parse_utf8_body(body, NativeBodyKind::Text)
}

fn parse_json_body(body: Bytes) -> Result<ValidatedBody, Response<Body>> {
    match serde_json::from_slice::<serde_json::Value>(body.as_ref()) {
        Ok(json) => Ok(ValidatedBody {
            bytes: Some(body.to_vec()),
            kind: NativeBodyKind::Json,
            json: Some(json),
        }),
        Err(_) => Err(response(
            StatusCode::BAD_REQUEST,
            "text/plain; charset=utf-8",
            "Invalid JSON body".to_string(),
        )),
    }
}

fn parse_utf8_body(body: Bytes, kind: NativeBodyKind) -> Result<ValidatedBody, Response<Body>> {
    match std::str::from_utf8(body.as_ref()) {
        Ok(_) => Ok(ValidatedBody {
            bytes: Some(body.to_vec()),
            kind,
            json: None,
        }),
        Err(_) => Err(response(
            StatusCode::BAD_REQUEST,
            "text/plain; charset=utf-8",
            "Request body must be valid UTF-8".to_string(),
        )),
    }
}

impl ValidatedBody {
    fn none() -> Self {
        Self {
            bytes: None,
            kind: NativeBodyKind::None,
            json: None,
        }
    }
}

fn validate_string_map(
    values: &HashMap<String, String>,
    schema_id: Option<&str>,
    label: &str,
    runtime_state: &ServerRuntimeState,
) -> Result<(), Response<Body>> {
    let Some(schema_id) = schema_id else {
        return Ok(());
    };

    let instance = serde_json::Value::Object(
        values
            .iter()
            .map(|(key, value)| (key.clone(), serde_json::Value::String(value.clone())))
            .collect(),
    );
    validate_schema_value(schema_id, &instance, label, runtime_state)
}

fn validate_request_body(
    body: &ValidatedBody,
    request_body: &RequestBodyValidation,
    runtime_state: &ServerRuntimeState,
) -> Result<(), Response<Body>> {
    let Some(schema_id) = request_body.schema_id.as_deref() else {
        return Ok(());
    };
    let instance = match body.kind {
        NativeBodyKind::Json => body
            .json
            .as_ref()
            .cloned()
            .unwrap_or(serde_json::Value::Null),
        NativeBodyKind::Text => match body.bytes.as_ref() {
            Some(bytes) => {
                serde_json::Value::String(String::from_utf8_lossy(bytes.as_slice()).into_owned())
            }
            None => serde_json::Value::Null,
        },
        NativeBodyKind::Multipart | NativeBodyKind::None => serde_json::Value::Null,
    };

    validate_schema_value(schema_id, &instance, "Request body", runtime_state)
}

fn validate_schema_value(
    schema_id: &str,
    instance: &serde_json::Value,
    label: &str,
    runtime_state: &ServerRuntimeState,
) -> Result<(), Response<Body>> {
    let Some(validator) = runtime_state.schemas.get(schema_id) else {
        return Err(response(
            StatusCode::INTERNAL_SERVER_ERROR,
            "text/plain; charset=utf-8",
            format!("Missing compiled schema '{schema_id}'"),
        ));
    };

    if validator.is_valid(instance) {
        return Ok(());
    }

    let detail = validator
        .iter_errors(instance)
        .next()
        .map(|error| error.to_string())
        .unwrap_or_else(|| "Unknown schema validation error".to_string());
    Err(response(
        StatusCode::UNPROCESSABLE_ENTITY,
        "text/plain; charset=utf-8",
        format!("{label} validation failed: {detail}"),
    ))
}

fn response(status: StatusCode, content_type: &str, body: String) -> Response<Body> {
    response_with_headers(status, content_type, &[], body)
}

fn response_with_headers(
    status: StatusCode,
    content_type: &str,
    headers: &[(String, String)],
    body: String,
) -> Response<Body> {
    response_body_with_headers(status, content_type, headers, Body::from(body))
}

fn path_segments(path: &str) -> Vec<&str> {
    if path == "/" {
        return Vec::new();
    }

    path.split('/')
        .filter(|segment| !segment.is_empty())
        .collect()
}

fn body_kind(content_type: &str) -> RequestBodyKind {
    match content_type_essence(content_type) {
        "application/json" => RequestBodyKind::Json,
        "multipart/form-data" => RequestBodyKind::Multipart,
        "text/plain" => RequestBodyKind::Text,
        _ => RequestBodyKind::Other,
    }
}

fn content_type_matches(actual: Option<&str>, expected: &str) -> bool {
    let Some(actual) = actual else {
        return false;
    };

    content_type_essence(actual).eq_ignore_ascii_case(content_type_essence(expected))
}

fn content_type_essence(value: &str) -> &str {
    value.split(';').next().unwrap_or_default().trim()
}

fn parse_query(query: Option<&str>) -> HashMap<String, String> {
    let mut result = HashMap::new();
    if let Some(query) = query {
        for pair in query.split('&') {
            if pair.is_empty() {
                continue;
            }
            let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
            result.insert(decode_query_component(key), decode_query_component(value));
        }
    }
    result
}

fn decode_query_component(value: &str) -> String {
    let mut decoded = Vec::with_capacity(value.len());
    let bytes = value.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'+' => {
                decoded.push(b' ');
                index += 1;
            }
            b'%' if index + 2 < bytes.len() => {
                if let (Some(high), Some(low)) =
                    (hex_value(bytes[index + 1]), hex_value(bytes[index + 2]))
                {
                    decoded.push((high << 4) | low);
                    index += 3;
                } else {
                    decoded.push(bytes[index]);
                    index += 1;
                }
            }
            byte => {
                decoded.push(byte);
                index += 1;
            }
        }
    }
    String::from_utf8_lossy(&decoded).into_owned()
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn collect_headers(headers: &HeaderMap) -> HashMap<String, String> {
    headers
        .iter()
        .map(|(name, value)| {
            let value = value.to_str().unwrap_or_default().to_string();
            (name.as_str().to_string(), value)
        })
        .collect()
}

fn boxed_ptr<T>(values: &[T]) -> *const T {
    if values.is_empty() {
        std::ptr::null()
    } else {
        values.as_ptr()
    }
}

fn set_last_error(message: impl Into<String>) {
    *LAST_ERROR.lock().unwrap() = Some(message.into());
}

fn clear_last_error() {
    *LAST_ERROR.lock().unwrap() = None;
}

fn parse_multipart_boundary(content_type: &str) -> Result<String, String> {
    if !content_type_essence(content_type).eq_ignore_ascii_case("multipart/form-data") {
        return Err("Expected multipart/form-data request.".to_string());
    }

    for parameter in content_type.split(';').skip(1) {
        let Some((name, value)) = parameter.trim().split_once('=') else {
            continue;
        };
        if !name.trim().eq_ignore_ascii_case("boundary") {
            continue;
        }

        let boundary = trim_header_parameter(value.trim());
        if boundary.is_empty() {
            return Err("Multipart boundary must not be empty.".to_string());
        }
        return Ok(boundary.to_string());
    }

    Err("Missing multipart boundary.".to_string())
}

fn parse_multipart_form(body: &[u8], boundary: &str) -> Result<ParsedMultipartForm, String> {
    let boundary_marker = format!("--{boundary}").into_bytes();
    let part_delimiter = format!("\r\n--{boundary}").into_bytes();
    let mut cursor = 0;
    let mut fields = Vec::new();
    let mut files = Vec::new();

    if !body.starts_with(&boundary_marker) {
        return Err("Multipart body does not start with the declared boundary.".to_string());
    }

    loop {
        cursor += boundary_marker.len();

        if body.get(cursor..cursor + 2) == Some(b"--") {
            cursor += 2;
            if body.get(cursor..cursor + 2) == Some(b"\r\n") {
                cursor += 2;
            }
            if cursor != body.len() {
                return Err("Unexpected bytes after the closing multipart boundary.".to_string());
            }
            return Ok(ParsedMultipartForm { fields, files });
        }

        if body.get(cursor..cursor + 2) != Some(b"\r\n") {
            return Err("Invalid multipart boundary separator.".to_string());
        }
        cursor += 2;

        let Some(headers_end) = find_bytes(body, cursor, b"\r\n\r\n") else {
            return Err("Multipart part is missing a header terminator.".to_string());
        };
        let part_headers = parse_part_headers(&body[cursor..headers_end])?;
        cursor = headers_end + 4;

        let Some(content_disposition) = part_headers.get("content-disposition") else {
            return Err("Multipart part is missing Content-Disposition.".to_string());
        };
        let disposition = parse_content_disposition(content_disposition)?;

        let Some(part_end) = find_bytes(body, cursor, &part_delimiter) else {
            return Err("Multipart part is missing a closing boundary.".to_string());
        };
        let part_body = &body[cursor..part_end];

        if disposition.filename.is_some() {
            files.push(ParsedMultipartFile {
                field_name: disposition.name,
                filename: disposition.filename,
                content_type: part_headers.get("content-type").cloned(),
                body_start: cursor,
                body_len: part_body.len(),
            });
        } else {
            let value = std::str::from_utf8(part_body)
                .map_err(|_| {
                    format!(
                        "Multipart field '{}' must be valid UTF-8.",
                        disposition.name
                    )
                })?
                .to_string();
            fields.push(ParsedMultipartField {
                name: disposition.name,
                value,
            });
        }

        cursor = part_end + 2;
        if !body[cursor..].starts_with(&boundary_marker) {
            return Err("Multipart parser lost boundary alignment.".to_string());
        }
    }
}

fn parse_part_headers(header_block: &[u8]) -> Result<HashMap<String, String>, String> {
    let header_text = std::str::from_utf8(header_block)
        .map_err(|_| "Multipart part headers must be valid UTF-8.".to_string())?;
    let mut headers = HashMap::new();

    for line in header_text.split("\r\n") {
        if line.is_empty() {
            continue;
        }

        let Some((name, value)) = line.split_once(':') else {
            return Err(format!("Invalid multipart header line '{line}'."));
        };
        headers.insert(name.trim().to_ascii_lowercase(), value.trim().to_string());
    }

    Ok(headers)
}

fn parse_content_disposition(value: &str) -> Result<ParsedContentDisposition, String> {
    let mut parts = value.split(';');
    let Some(kind) = parts.next() else {
        return Err("Empty Content-Disposition header.".to_string());
    };
    if !kind.trim().eq_ignore_ascii_case("form-data") {
        return Err("Multipart Content-Disposition must be form-data.".to_string());
    }

    let mut name = None;
    let mut filename = None;

    for part in parts {
        let Some((parameter_name, parameter_value)) = part.trim().split_once('=') else {
            continue;
        };
        let decoded_value = trim_header_parameter(parameter_value.trim()).to_string();
        if parameter_name.trim().eq_ignore_ascii_case("name") {
            name = Some(decoded_value);
            continue;
        }
        if parameter_name.trim().eq_ignore_ascii_case("filename")
            || parameter_name.trim().eq_ignore_ascii_case("filename*")
        {
            filename = Some(decoded_value);
        }
    }

    let Some(name) = name else {
        return Err("Multipart part is missing a field name.".to_string());
    };

    Ok(ParsedContentDisposition { name, filename })
}

fn trim_header_parameter(value: &str) -> &str {
    if value.len() >= 2 && value.starts_with('"') && value.ends_with('"') {
        &value[1..value.len() - 1]
    } else {
        value
    }
}

fn find_bytes(haystack: &[u8], start: usize, needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || start > haystack.len() || haystack.len() - start < needle.len() {
        return None;
    }

    haystack[start..]
        .windows(needle.len())
        .position(|window| window == needle)
        .map(|offset| start + offset)
}

unsafe fn read_c_string(value: *const c_char) -> Option<String> {
    if value.is_null() {
        return None;
    }

    unsafe { CStr::from_ptr(value) }
        .to_str()
        .ok()
        .map(ToOwned::to_owned)
}

unsafe fn read_optional_c_string(value: *const c_char) -> Option<String> {
    if value.is_null() {
        return None;
    }

    unsafe { read_c_string(value) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use native_exchange_rust::abi::{
        NEX_ABI_VERSION, NEX_CAPABILITY_CONCURRENT_CANCEL, NEX_STREAM_READ_CHUNK,
        NEX_STREAM_READ_DONE, NexBuffer, NexUtf8View,
    };
    use serde_json::json;
    use std::ffi::c_void;
    use std::mem::size_of;
    use std::sync::atomic::{AtomicBool, AtomicUsize};

    struct TestStreamContext {
        emitted: AtomicBool,
        buffer_releases: Arc<AtomicUsize>,
        stream_releases: Arc<AtomicUsize>,
    }

    struct TestBufferContext {
        bytes: Vec<u8>,
        releases: Arc<AtomicUsize>,
    }

    unsafe extern "C" fn test_stream_next(
        context: *mut c_void,
        out_buffer: *mut NexBuffer,
        _out_error: *mut NexUtf8View,
    ) -> i32 {
        let context = unsafe { &*context.cast::<TestStreamContext>() };
        if context.emitted.swap(true, Ordering::AcqRel) {
            return NEX_STREAM_READ_DONE;
        }
        let mut buffer = Box::new(TestBufferContext {
            bytes: vec![1, 2, 3, 4],
            releases: Arc::clone(&context.buffer_releases),
        });
        let descriptor = NexBuffer {
            abi_version: NEX_ABI_VERSION,
            struct_size: size_of::<NexBuffer>(),
            capabilities: NEX_CAPABILITY_THREAD_SAFE,
            ptr: buffer.bytes.as_ptr(),
            len: buffer.bytes.len(),
            context: (&mut *buffer as *mut TestBufferContext).cast(),
            release: Some(test_buffer_release),
        };
        let _ = Box::into_raw(buffer);
        unsafe { out_buffer.write(descriptor) };
        NEX_STREAM_READ_CHUNK
    }

    unsafe extern "C" fn test_buffer_release(context: *mut c_void) {
        let context = unsafe { Box::from_raw(context.cast::<TestBufferContext>()) };
        context.releases.fetch_add(1, Ordering::AcqRel);
    }

    unsafe extern "C" fn test_stream_cancel(_context: *mut c_void) {}

    unsafe extern "C" fn test_stream_release(context: *mut c_void) {
        let context = unsafe { Box::from_raw(context.cast::<TestStreamContext>()) };
        context.stream_releases.fetch_add(1, Ordering::AcqRel);
    }

    #[test]
    fn consumes_native_exchange_stream_without_copying_chunk_ownership() {
        let buffer_releases = Arc::new(AtomicUsize::new(0));
        let stream_releases = Arc::new(AtomicUsize::new(0));
        let context = Box::new(TestStreamContext {
            emitted: AtomicBool::new(false),
            buffer_releases: Arc::clone(&buffer_releases),
            stream_releases: Arc::clone(&stream_releases),
        });
        let descriptor = NexByteStream {
            abi_version: NEX_ABI_VERSION,
            struct_size: size_of::<NexByteStream>(),
            capabilities: NEX_CAPABILITY_THREAD_SAFE | NEX_CAPABILITY_CONCURRENT_CANCEL,
            context: Box::into_raw(context).cast(),
            next: Some(test_stream_next),
            cancel: Some(test_stream_cancel),
            release: Some(test_stream_release),
        };
        let stream =
            unsafe { AdoptedByteStream::adopt(descriptor) }.expect("test stream should be adopted");

        let chunk = match stream.reader().read_next().expect("stream read succeeds") {
            StreamRead::Chunk(chunk) => chunk.into_bytes(),
            StreamRead::Done | StreamRead::Canceled => {
                panic!("stream ended before its chunk")
            }
        };
        assert_eq!(&chunk[..], &[1, 2, 3, 4]);
        assert_eq!(buffer_releases.load(Ordering::Acquire), 0);
        drop(chunk);
        assert_eq!(buffer_releases.load(Ordering::Acquire), 1);

        assert!(matches!(
            stream.reader().read_next().expect("terminal read succeeds"),
            StreamRead::Done,
        ));
        drop(stream);
        assert_eq!(stream_releases.load(Ordering::Acquire), 1);
    }

    #[test]
    fn compiles_installed_schemas_with_component_refs() {
        let schemas = HashMap::from([
            (
                "ListSort".to_string(),
                json!({
                    "$id": "ListSort",
                    "type": "array",
                    "items": {
                        "$ref": "#/components/schemas/ListSortItem",
                    },
                }),
            ),
            (
                "ListSortItem".to_string(),
                json!({
                    "$id": "ListSortItem",
                    "type": "object",
                    "properties": {
                        "field": {
                            "type": "string",
                        },
                    },
                    "required": ["field"],
                    "additionalProperties": false,
                }),
            ),
        ]);

        let validators = compile_schemas(schemas).expect("schemas compile");
        let validator = validators.get("ListSort").expect("ListSort validator");

        assert!(validator.is_valid(&json!([{ "field": "createdAt" }])));
        assert!(!validator.is_valid(&json!([{ "field": 42 }])));
    }

    #[test]
    fn parse_query_decodes_percent_encoded_components() {
        let query = parse_query(Some(
            "callbackURL=http%3A%2F%2F127.0.0.1%3A51663%2Fcallback&name=Ada+Lovelace",
        ));

        assert_eq!(
            query.get("callbackURL").map(String::as_str),
            Some("http://127.0.0.1:51663/callback"),
        );
        assert_eq!(query.get("name").map(String::as_str), Some("Ada Lovelace"));
    }

    #[test]
    fn parse_query_preserves_invalid_percent_escapes() {
        let query = parse_query(Some("value=bad%zz%2"));

        assert_eq!(query.get("value").map(String::as_str), Some("bad%zz%2"));
    }

    #[test]
    fn bounds_web_socket_ingress_by_count_and_bytes() {
        let session_id = NEXT_WEB_SOCKET_SESSION_ID.fetch_add(1, Ordering::Relaxed);
        let (command_tx, _command_rx) = mpsc::unbounded_channel();
        WEB_SOCKET_SESSIONS.lock().unwrap().insert(
            session_id,
            WebSocketSessionState {
                server_id: 1,
                connection: None,
                messages: VecDeque::new(),
                pending_bytes: 0,
                max_pending_messages: 1,
                max_pending_bytes: 4,
                command_tx,
            },
        );

        assert!(push_web_socket_message(
            session_id,
            WebSocketIncomingMessage {
                session_id,
                kind: WebSocketMessageKind::Binary,
                body: vec![0; 4],
            },
        ));
        assert!(!push_web_socket_message(
            session_id,
            WebSocketIncomingMessage {
                session_id,
                kind: WebSocketMessageKind::Binary,
                body: vec![0],
            },
        ));

        let session = WEB_SOCKET_SESSIONS
            .lock()
            .unwrap()
            .remove(&session_id)
            .unwrap();
        assert_eq!(session.messages.len(), 1);
        assert_eq!(session.pending_bytes, 4);
    }

    #[test]
    fn bounds_combined_web_transport_compatibility_ingress() {
        let session_id = NEXT_WEB_TRANSPORT_SESSION_ID.fetch_add(1, Ordering::Relaxed);
        let (command_tx, _command_rx) = mpsc::unbounded_channel();
        WEB_TRANSPORT_SESSIONS.lock().unwrap().insert(
            session_id,
            WebTransportSessionState {
                server_id: 1,
                connection: None,
                datagrams: VecDeque::new(),
                streams: VecDeque::new(),
                pending_bytes: 0,
                max_pending_messages: 2,
                max_pending_bytes: 4,
                command_tx,
            },
        );

        assert!(push_web_transport_datagram(
            session_id,
            WebTransportIncomingDatagram {
                session_id,
                body: vec![0; 2],
            },
        ));
        assert!(push_web_transport_stream(
            session_id,
            WebTransportIncomingStream {
                session_id,
                body: vec![0; 2],
            },
        ));
        assert!(!push_web_transport_datagram(
            session_id,
            WebTransportIncomingDatagram {
                session_id,
                body: vec![0],
            },
        ));

        let session = WEB_TRANSPORT_SESSIONS
            .lock()
            .unwrap()
            .remove(&session_id)
            .unwrap();
        assert_eq!(session.datagrams.len() + session.streams.len(), 2);
        assert_eq!(session.pending_bytes, 4);
    }
}
