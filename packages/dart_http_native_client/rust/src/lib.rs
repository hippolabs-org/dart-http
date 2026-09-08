use std::collections::HashMap;
use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::io;
use std::mem::size_of;
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use bytes::Bytes;
use futures_util::{SinkExt, StreamExt};
use native_exchange_abi::{
    NEX_ABI_VERSION, NEX_CAPABILITY_CONCURRENT_CANCEL, NEX_CAPABILITY_THREAD_SAFE,
    NEX_STREAM_READ_CANCELED, NEX_STREAM_READ_CHUNK, NEX_STREAM_READ_DONE, NEX_STREAM_READ_ERROR,
    NexBuffer, NexByteStream, NexUtf8View,
};
use once_cell::sync::Lazy;
use reqwest::{Body, Client, Method, Url};
use tokio::runtime::{Builder, Runtime};
use tokio::sync::mpsc;
use tokio_stream::wrappers::ReceiverStream;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::{HeaderName, HeaderValue};
use tokio_tungstenite::tungstenite::protocol::{
    CloseFrame,
    frame::{
        Frame,
        coding::{CloseCode, Data, OpCode},
    },
};
use tokio_util::sync::CancellationToken;

const ABI_VERSION: i32 = 4;
const REQUEST_CANCELED: &str = "Native HTTP request canceled.";
const WEBSOCKET_EVENT_OPENED: i32 = 1;
const WEBSOCKET_EVENT_TEXT: i32 = 2;
const WEBSOCKET_EVENT_BINARY: i32 = 3;
const WEBSOCKET_EVENT_CLOSED: i32 = 4;
const WEBSOCKET_EVENT_ERROR: i32 = 5;
const WEBSOCKET_EVENT_SENT: i32 = 6;

static RUNTIME: Lazy<Runtime> = Lazy::new(|| {
    Builder::new_multi_thread()
        .enable_all()
        .thread_name("dart-http-native")
        .build()
        .expect("native HTTP Tokio runtime must initialize")
});
static CLIENTS: Lazy<Mutex<HashMap<i64, Arc<ClientState>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static NEXT_CLIENT_ID: AtomicI64 = AtomicI64::new(1);

#[repr(C)]
pub struct NativeHttpHeader {
    name: *const c_char,
    value: *const c_char,
}

#[repr(C)]
pub struct NativeHttpResult {
    success: bool,
    status_code: i32,
    metadata_json: *mut c_char,
    body_stream: *mut c_void,
    error: *mut c_char,
}

#[repr(C)]
pub struct NativeWebSocketEvent {
    kind: i32,
    socket_id: i64,
    operation_id: i64,
    close_code: i32,
    text: *mut c_char,
    binary_buffer: *mut c_void,
}

struct ClientState {
    client: Client,
    connect_timeout: Duration,
    completion_port: NativeCompletionPort,
    next_request_id: AtomicI64,
    next_socket_id: AtomicI64,
    tasks: Mutex<HashMap<i64, RequestTask>>,
    results: Mutex<HashMap<i64, Result<ResponseData, String>>>,
    web_sockets: Mutex<HashMap<i64, Arc<WebSocketState>>>,
    closed: AtomicBool,
}

struct RequestTask {
    cancellation: CancellationToken,
    native_body_cancel: Option<RequestStreamCancel>,
}

struct WebSocketState {
    commands: mpsc::Sender<WebSocketCommand>,
    events: Mutex<mpsc::Receiver<WebSocketEventData>>,
    control_events: Mutex<mpsc::UnboundedReceiver<WebSocketEventData>>,
    cancellation: CancellationToken,
    next_operation_id: AtomicI64,
}

enum WebSocketCommand {
    Send {
        operation_id: i64,
        messages: Vec<Message>,
    },
    Close {
        operation_id: i64,
        code: Option<u16>,
        reason: String,
    },
}

enum WebSocketEventData {
    Opened { protocol: Option<String> },
    Text(String),
    Binary(Bytes),
    Closed { code: Option<u16>, reason: String },
    Error(String),
    Sent { operation_id: i64 },
}

struct AdoptedRequestStream {
    inner: Arc<RequestStreamInner>,
}

impl AdoptedRequestStream {
    fn adopt(descriptor: NexByteStream) -> Result<Self, String> {
        if !descriptor.is_valid() || descriptor.capabilities & NEX_CAPABILITY_THREAD_SAFE == 0 {
            return Err(
                "Native request body must support foreign-thread Native Exchange reads.".to_owned(),
            );
        }
        Ok(Self {
            inner: Arc::new(RequestStreamInner {
                descriptor,
                read_lock: Mutex::new(()),
                terminal: AtomicBool::new(false),
                canceled: AtomicBool::new(false),
            }),
        })
    }

    fn reader(&self) -> RequestStreamReader {
        RequestStreamReader(Arc::clone(&self.inner))
    }

    fn cancel_handle(&self) -> Option<RequestStreamCancel> {
        if self.inner.descriptor.capabilities & NEX_CAPABILITY_CONCURRENT_CANCEL == 0
            || self.inner.descriptor.cancel.is_none()
        {
            return None;
        }
        Some(RequestStreamCancel(Arc::clone(&self.inner)))
    }
}

struct RequestStreamReader(Arc<RequestStreamInner>);

impl RequestStreamReader {
    fn read_next(&self) -> Result<RequestStreamRead, String> {
        let _guard = self
            .0
            .read_lock
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if self.0.terminal.load(Ordering::Acquire) {
            return Ok(RequestStreamRead::Done);
        }
        let next = self
            .0
            .descriptor
            .next
            .expect("adopted Native Exchange stream was validated");
        let mut buffer = NexBuffer {
            abi_version: 0,
            struct_size: 0,
            capabilities: 0,
            ptr: ptr::null(),
            len: 0,
            context: ptr::null_mut(),
            release: None,
        };
        let mut error = NexUtf8View::empty();
        let status = unsafe { next(self.0.descriptor.context, &mut buffer, &mut error) };
        match status {
            NEX_STREAM_READ_CHUNK => {
                if !buffer.is_valid() || buffer.capabilities & NEX_CAPABILITY_THREAD_SAFE == 0 {
                    release_buffer(buffer);
                    self.0.cancel();
                    return Err("Native request body returned an invalid buffer.".to_owned());
                }
                Ok(RequestStreamRead::Chunk(Bytes::from_owner(
                    AdoptedBufferOwner(Some(buffer)),
                )))
            }
            NEX_STREAM_READ_DONE | NEX_STREAM_READ_CANCELED => {
                self.0.terminal.store(true, Ordering::Release);
                Ok(RequestStreamRead::Done)
            }
            NEX_STREAM_READ_ERROR => {
                self.0.terminal.store(true, Ordering::Release);
                Err(copy_diagnostic(error))
            }
            other => {
                self.0.cancel();
                Err(format!(
                    "Native request body returned unknown status {other}."
                ))
            }
        }
    }
}

enum RequestStreamRead {
    Chunk(Bytes),
    Done,
}

#[derive(Clone)]
struct RequestStreamCancel(Arc<RequestStreamInner>);

impl RequestStreamCancel {
    fn cancel(&self) {
        self.0.cancel();
    }
}

struct RequestStreamInner {
    descriptor: NexByteStream,
    read_lock: Mutex<()>,
    terminal: AtomicBool,
    canceled: AtomicBool,
}

impl RequestStreamInner {
    fn cancel(&self) {
        if self.terminal.load(Ordering::Acquire) || self.canceled.swap(true, Ordering::AcqRel) {
            return;
        }
        if let Some(cancel) = self.descriptor.cancel {
            unsafe { cancel(self.descriptor.context) };
        }
    }
}

impl Drop for RequestStreamInner {
    fn drop(&mut self) {
        if !self.terminal.load(Ordering::Acquire)
            && !self.canceled.swap(true, Ordering::AcqRel)
            && let Some(cancel) = self.descriptor.cancel
        {
            unsafe { cancel(self.descriptor.context) };
        }
        if let Some(release) = self.descriptor.release {
            unsafe { release(self.descriptor.context) };
        }
    }
}

unsafe impl Send for RequestStreamInner {}
unsafe impl Sync for RequestStreamInner {}

struct AdoptedBufferOwner(Option<NexBuffer>);

impl AsRef<[u8]> for AdoptedBufferOwner {
    fn as_ref(&self) -> &[u8] {
        let descriptor = self.0.as_ref().expect("request buffer is still owned");
        if descriptor.len == 0 {
            return &[];
        }
        unsafe { std::slice::from_raw_parts(descriptor.ptr, descriptor.len) }
    }
}

impl Drop for AdoptedBufferOwner {
    fn drop(&mut self) {
        if let Some(descriptor) = self.0.take() {
            release_buffer(descriptor);
        }
    }
}

unsafe impl Send for AdoptedBufferOwner {}
unsafe impl Sync for AdoptedBufferOwner {}

struct ResponseData {
    status: i32,
    metadata_json: String,
    body_stream: Option<usize>,
}

impl ResponseData {
    fn into_ffi(mut self) -> NativeHttpResult {
        NativeHttpResult {
            success: true,
            status_code: self.status,
            metadata_json: c_string(std::mem::take(&mut self.metadata_json)),
            body_stream: self.body_stream.take().unwrap_or_default() as *mut c_void,
            error: ptr::null_mut(),
        }
    }
}

impl Drop for ResponseData {
    fn drop(&mut self) {
        let Some(address) = self.body_stream.take() else {
            return;
        };
        unsafe { release_stream_pointer(address as *mut NexByteStream) };
    }
}

#[unsafe(no_mangle)]
/// Initializes the subset of the Dart native API required for completion ports.
///
/// # Safety
///
/// `data` must be the valid `NativeApi.initializeApiDLData` pointer supplied by
/// the Dart VM, and it must remain valid for the duration of this call.
pub unsafe extern "C" fn dart_http_native_client_initialize_api_dl(data: *mut c_void) -> i32 {
    match unsafe { initialize_dart_api_dl(data) } {
        Ok(()) => 0,
        Err(_) => -1,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_native_client_abi_version() -> i32 {
    ABI_VERSION
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_native_client_create(
    completion_port: i64,
    connect_timeout_ms: i64,
    request_timeout_ms: i64,
) -> i64 {
    let Some(connect_timeout) = positive_duration(connect_timeout_ms) else {
        return 0;
    };
    let Some(request_timeout) = positive_duration(request_timeout_ms) else {
        return 0;
    };
    let client = match Client::builder()
        .connect_timeout(connect_timeout)
        .timeout(request_timeout)
        .build()
    {
        Ok(client) => client,
        Err(_) => return 0,
    };
    let id = NEXT_CLIENT_ID.fetch_add(1, Ordering::Relaxed);
    let state = Arc::new(ClientState {
        client,
        connect_timeout,
        completion_port: NativeCompletionPort::new(completion_port),
        next_request_id: AtomicI64::new(1),
        next_socket_id: AtomicI64::new(1),
        tasks: Mutex::new(HashMap::new()),
        results: Mutex::new(HashMap::new()),
        web_sockets: Mutex::new(HashMap::new()),
        closed: AtomicBool::new(false),
    });
    match CLIENTS.lock() {
        Ok(mut clients) => {
            clients.insert(id, state);
            id
        }
        Err(_) => 0,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_native_client_close(client_id: i64) {
    let state = CLIENTS
        .lock()
        .ok()
        .and_then(|mut clients| clients.remove(&client_id));
    let Some(state) = state else {
        return;
    };
    state.closed.store(true, Ordering::Release);
    if let Ok(mut tasks) = state.tasks.lock() {
        for (_, task) in tasks.drain() {
            task.cancellation.cancel();
            if let Some(cancel) = task.native_body_cancel {
                cancel.cancel();
            }
        }
    }
    if let Ok(mut results) = state.results.lock() {
        results.clear();
    }
    if let Ok(mut sockets) = state.web_sockets.lock() {
        for (_, socket) in sockets.drain() {
            socket.cancellation.cancel();
        }
    }
}

#[unsafe(no_mangle)]
/// Starts an asynchronous HTTP request and returns its request identifier.
///
/// # Safety
///
/// Every pointer must either be null where permitted or point to readable data
/// of its corresponding length for the duration of this call. `native_body`,
/// when non-null, must own a valid `NexByteStream` descriptor that this function
/// may adopt.
pub unsafe extern "C" fn dart_http_native_client_start(
    client_id: i64,
    method: *const c_char,
    url: *const c_char,
    headers: *const NativeHttpHeader,
    header_count: isize,
    body: *const u8,
    body_length: isize,
    native_body: *mut c_void,
    native_body_length: i64,
    native_prefix: *const u8,
    native_prefix_length: isize,
    native_suffix: *const u8,
    native_suffix_length: isize,
) -> i64 {
    let Some(state) = client_state(client_id) else {
        return 0;
    };
    if state.closed.load(Ordering::Acquire) {
        return 0;
    }
    let request = unsafe {
        prepare_request(
            &state,
            method,
            url,
            headers,
            header_count,
            body,
            body_length,
            native_body,
            native_body_length,
            native_prefix,
            native_prefix_length,
            native_suffix,
            native_suffix_length,
        )
    };
    let Ok((request, native_body_cancel)) = request else {
        return 0;
    };
    let request_id = state.next_request_id.fetch_add(1, Ordering::Relaxed);
    let cancellation = CancellationToken::new();
    if let Ok(mut tasks) = state.tasks.lock() {
        tasks.insert(
            request_id,
            RequestTask {
                cancellation: cancellation.clone(),
                native_body_cancel,
            },
        );
    } else {
        return 0;
    }

    let task_state = Arc::clone(&state);
    RUNTIME.spawn(async move {
        let result = tokio::select! {
            () = cancellation.cancelled() => Err(REQUEST_CANCELED.to_owned()),
            result = send_request(task_state.client.clone(), request, cancellation.clone()) => result,
        };
        complete_request(&task_state, request_id, result);
    });
    request_id
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_native_client_cancel(client_id: i64, request_id: i64) -> bool {
    let Some(state) = client_state(client_id) else {
        return false;
    };
    let task = state
        .tasks
        .lock()
        .ok()
        .and_then(|mut tasks| tasks.remove(&request_id));
    let Some(task) = task else {
        return false;
    };
    task.cancellation.cancel();
    if let Some(cancel) = task.native_body_cancel {
        cancel.cancel();
    }
    true
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_native_client_take_result(
    client_id: i64,
    request_id: i64,
) -> *mut NativeHttpResult {
    let Some(state) = client_state(client_id) else {
        return ptr::null_mut();
    };
    let result = state
        .results
        .lock()
        .ok()
        .and_then(|mut results| results.remove(&request_id));
    let Some(result) = result else {
        return ptr::null_mut();
    };
    let result = match result {
        Ok(response) => response.into_ffi(),
        Err(error) => NativeHttpResult {
            success: false,
            status_code: 0,
            metadata_json: ptr::null_mut(),
            body_stream: ptr::null_mut(),
            error: c_string(error),
        },
    };
    Box::into_raw(Box::new(result))
}

#[unsafe(no_mangle)]
/// Releases a result returned by `dart_http_native_client_take_result`.
///
/// # Safety
///
/// `result` must be null or a pointer returned by
/// `dart_http_native_client_take_result` that has not previously been freed.
pub unsafe extern "C" fn dart_http_native_client_free_result(result: *mut NativeHttpResult) {
    if result.is_null() {
        return;
    }
    let result = unsafe { Box::from_raw(result) };
    unsafe {
        free_c_string(result.metadata_json);
        free_c_string(result.error);
        if !result.body_stream.is_null() {
            drop(Box::from_raw(result.body_stream.cast::<NexByteStream>()));
        }
    }
}

#[unsafe(no_mangle)]
/// Starts an asynchronous native WebSocket connection.
///
/// # Safety
///
/// String and header pointers must remain readable for this call. All values
/// are copied before the function returns.
pub unsafe extern "C" fn dart_http_native_client_websocket_connect(
    client_id: i64,
    url: *const c_char,
    headers: *const NativeHttpHeader,
    header_count: isize,
    protocols: *const *const c_char,
    protocol_count: isize,
    incoming_capacity: isize,
    outgoing_capacity: isize,
) -> i64 {
    let Some(state) = client_state(client_id) else {
        return 0;
    };
    if state.closed.load(Ordering::Acquire) {
        return 0;
    }
    let Some(incoming_capacity) = bounded_capacity(incoming_capacity) else {
        return 0;
    };
    let Some(outgoing_capacity) = bounded_capacity(outgoing_capacity) else {
        return 0;
    };
    let url = match unsafe { required_c_str(url, "WebSocket URL") } {
        Ok(value) => value,
        Err(_) => return 0,
    };
    let headers = match unsafe { read_headers(headers, header_count) } {
        Ok(value) => value,
        Err(_) => return 0,
    };
    let protocols = match unsafe { read_c_string_array(protocols, protocol_count) } {
        Ok(value) => value,
        Err(_) => return 0,
    };
    let socket_id = state.next_socket_id.fetch_add(1, Ordering::Relaxed);
    let (command_tx, command_rx) = mpsc::channel(outgoing_capacity);
    let (event_tx, event_rx) = mpsc::channel(incoming_capacity);
    let (control_event_tx, control_event_rx) = mpsc::unbounded_channel();
    let cancellation = CancellationToken::new();
    let socket = Arc::new(WebSocketState {
        commands: command_tx,
        events: Mutex::new(event_rx),
        control_events: Mutex::new(control_event_rx),
        cancellation: cancellation.clone(),
        next_operation_id: AtomicI64::new(1),
    });
    let inserted = match state.web_sockets.lock() {
        Ok(mut sockets) => sockets.insert(socket_id, socket).is_none(),
        Err(_) => false,
    };
    if !inserted {
        return 0;
    }
    let task_state = Arc::clone(&state);
    RUNTIME.spawn(async move {
        run_web_socket(
            task_state,
            socket_id,
            url,
            headers,
            protocols,
            command_rx,
            event_tx,
            control_event_tx,
            cancellation,
        )
        .await;
    });
    socket_id
}

#[unsafe(no_mangle)]
/// Enqueues one UTF-8 WebSocket text frame.
///
/// # Safety
///
/// `value` must point to a valid null-terminated UTF-8 string for this call.
pub unsafe extern "C" fn dart_http_native_client_websocket_send_text(
    client_id: i64,
    socket_id: i64,
    value: *const c_char,
) -> i64 {
    let value = match unsafe { required_c_str(value, "WebSocket text") } {
        Ok(value) => value,
        Err(_) => return 0,
    };
    enqueue_web_socket_message(client_id, socket_id, Message::Text(value.into()))
}

#[unsafe(no_mangle)]
/// Enqueues one WebSocket binary frame after copying its bytes.
///
/// # Safety
///
/// `value` must be null only when `length` is zero and otherwise point to
/// `length` readable bytes for this call.
pub unsafe extern "C" fn dart_http_native_client_websocket_send_binary(
    client_id: i64,
    socket_id: i64,
    value: *const u8,
    length: isize,
) -> i64 {
    let bytes = match unsafe { copy_optional_bytes(value, length) } {
        Ok(value) => value,
        Err(_) => return 0,
    };
    enqueue_web_socket_message(client_id, socket_id, Message::Binary(bytes.into()))
}

#[unsafe(no_mangle)]
/// Enqueues one logical WebSocket binary message by adopting a Native Exchange
/// buffer. A non-empty prefix is emitted as the first fragment and the adopted
/// buffer as the final continuation fragment.
///
/// A positive result is the send operation ID. `-1` means ownership moved but
/// the bounded WebSocket queue rejected and released the frame. `0` means the
/// descriptor was not adopted.
///
/// # Safety
///
/// `native_buffer` must point to a live `NexBuffer` descriptor until this call
/// returns. The buffer must support release from a foreign thread.
pub unsafe extern "C" fn dart_http_native_client_websocket_send_binary_native_prefixed(
    client_id: i64,
    socket_id: i64,
    prefix: *const u8,
    prefix_length: isize,
    native_buffer: *mut c_void,
) -> i64 {
    if native_buffer.is_null() {
        return 0;
    }
    let descriptor_pointer = native_buffer.cast::<NexBuffer>();
    let descriptor = unsafe { &*descriptor_pointer };
    if !descriptor.is_valid() || descriptor.capabilities & NEX_CAPABILITY_THREAD_SAFE == 0 {
        return 0;
    }
    let prefix = match unsafe { copy_optional_bytes(prefix, prefix_length) } {
        Ok(value) => value,
        Err(_) => return 0,
    };
    let descriptor = unsafe { ptr::read(descriptor_pointer) };
    let bytes = Bytes::from_owner(AdoptedBufferOwner(Some(descriptor)));
    let messages = if prefix.is_empty() {
        vec![Message::Binary(bytes)]
    } else {
        vec![
            Message::Frame(Frame::message(prefix, OpCode::Data(Data::Binary), false)),
            Message::Frame(Frame::message(bytes, OpCode::Data(Data::Continue), true)),
        ]
    };
    match enqueue_web_socket_messages(client_id, socket_id, messages) {
        0 => -1,
        operation_id => operation_id,
    }
}

#[unsafe(no_mangle)]
/// Enqueues a graceful WebSocket close frame.
///
/// # Safety
///
/// `reason` may be null or must point to a valid null-terminated UTF-8 string
/// for this call.
pub unsafe extern "C" fn dart_http_native_client_websocket_close(
    client_id: i64,
    socket_id: i64,
    code: i32,
    reason: *const c_char,
) -> i64 {
    let Some(socket) = web_socket_state(client_id, socket_id) else {
        return 0;
    };
    let code = if code < 0 {
        None
    } else {
        match u16::try_from(code) {
            Ok(value) => Some(value),
            Err(_) => return 0,
        }
    };
    let reason = if reason.is_null() {
        String::new()
    } else {
        match unsafe { required_c_str(reason, "WebSocket close reason") } {
            Ok(value) => value,
            Err(_) => return 0,
        }
    };
    let operation_id = socket.next_operation_id.fetch_add(1, Ordering::Relaxed);
    match socket.commands.try_send(WebSocketCommand::Close {
        operation_id,
        code,
        reason,
    }) {
        Ok(()) => operation_id,
        Err(_) => 0,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_native_client_websocket_abort(client_id: i64, socket_id: i64) -> bool {
    let Some(state) = client_state(client_id) else {
        return false;
    };
    let socket = state
        .web_sockets
        .lock()
        .ok()
        .and_then(|mut sockets| sockets.remove(&socket_id));
    let Some(socket) = socket else {
        return false;
    };
    socket.cancellation.cancel();
    true
}

#[unsafe(no_mangle)]
pub extern "C" fn dart_http_native_client_websocket_take_event(
    client_id: i64,
    socket_id: i64,
    kind: i32,
) -> *mut NativeWebSocketEvent {
    let Some(socket) = web_socket_state(client_id, socket_id) else {
        return ptr::null_mut();
    };
    let event = if matches!(kind, WEBSOCKET_EVENT_TEXT | WEBSOCKET_EVENT_BINARY) {
        socket
            .events
            .lock()
            .ok()
            .and_then(|mut events| events.try_recv().ok())
    } else {
        socket
            .control_events
            .lock()
            .ok()
            .and_then(|mut events| events.try_recv().ok())
    };
    event
        .map(|event| Box::into_raw(Box::new(web_socket_event_to_ffi(socket_id, event))))
        .unwrap_or(ptr::null_mut())
}

#[unsafe(no_mangle)]
/// Transfers the Native Exchange buffer owned by a binary event.
///
/// # Safety
///
/// `event` must point to a live event returned by
/// `dart_http_native_client_websocket_take_event`.
pub unsafe extern "C" fn dart_http_native_client_websocket_event_take_binary(
    event: *mut NativeWebSocketEvent,
    out_buffer: *mut c_void,
) -> bool {
    if event.is_null() || out_buffer.is_null() {
        return false;
    }
    let event = unsafe { &mut *event };
    let pointer = std::mem::replace(&mut event.binary_buffer, ptr::null_mut());
    if pointer.is_null() {
        return false;
    }
    let descriptor = unsafe { *Box::from_raw(pointer.cast::<NexBuffer>()) };
    unsafe { out_buffer.cast::<NexBuffer>().write(descriptor) };
    true
}

#[unsafe(no_mangle)]
/// Releases a native WebSocket event and any payload it still owns.
///
/// # Safety
///
/// `event` must be null or a pointer returned by
/// `dart_http_native_client_websocket_take_event` that has not been freed.
pub unsafe extern "C" fn dart_http_native_client_websocket_free_event(
    event: *mut NativeWebSocketEvent,
) {
    if event.is_null() {
        return;
    }
    let event = unsafe { Box::from_raw(event) };
    unsafe { free_c_string(event.text) };
    if !event.binary_buffer.is_null() {
        unsafe { release_buffer_pointer(event.binary_buffer.cast::<NexBuffer>()) };
    }
}

fn enqueue_web_socket_message(client_id: i64, socket_id: i64, message: Message) -> i64 {
    enqueue_web_socket_messages(client_id, socket_id, vec![message])
}

fn enqueue_web_socket_messages(client_id: i64, socket_id: i64, messages: Vec<Message>) -> i64 {
    let Some(socket) = web_socket_state(client_id, socket_id) else {
        return 0;
    };
    let operation_id = socket.next_operation_id.fetch_add(1, Ordering::Relaxed);
    match socket.commands.try_send(WebSocketCommand::Send {
        operation_id,
        messages,
    }) {
        Ok(()) => operation_id,
        Err(_) => 0,
    }
}

fn web_socket_state(client_id: i64, socket_id: i64) -> Option<Arc<WebSocketState>> {
    client_state(client_id).and_then(|state| {
        state
            .web_sockets
            .lock()
            .ok()
            .and_then(|sockets| sockets.get(&socket_id).cloned())
    })
}

#[allow(clippy::too_many_arguments)]
async fn run_web_socket(
    state: Arc<ClientState>,
    socket_id: i64,
    url: String,
    headers: Vec<(String, String)>,
    protocols: Vec<String>,
    mut commands: mpsc::Receiver<WebSocketCommand>,
    events: mpsc::Sender<WebSocketEventData>,
    control_events: mpsc::UnboundedSender<WebSocketEventData>,
    cancellation: CancellationToken,
) {
    let request = prepare_web_socket_request(&url, headers, protocols);
    let request = match request {
        Ok(request) => request,
        Err(error) => {
            let _ = send_web_socket_event(
                &state,
                socket_id,
                &events,
                &control_events,
                WebSocketEventData::Error(error),
                &cancellation,
            )
            .await;
            return;
        }
    };
    let connected = tokio::time::timeout(state.connect_timeout, connect_async(request)).await;
    let (socket, response) = match connected {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => {
            let _ = send_web_socket_event(
                &state,
                socket_id,
                &events,
                &control_events,
                WebSocketEventData::Error(format!("Native WebSocket connection failed: {error}")),
                &cancellation,
            )
            .await;
            return;
        }
        Err(_) => {
            let _ = send_web_socket_event(
                &state,
                socket_id,
                &events,
                &control_events,
                WebSocketEventData::Error("Native WebSocket connection timed out.".to_owned()),
                &cancellation,
            )
            .await;
            return;
        }
    };
    let protocol = response
        .headers()
        .get("sec-websocket-protocol")
        .and_then(|value| value.to_str().ok())
        .map(ToOwned::to_owned);
    if !send_web_socket_event(
        &state,
        socket_id,
        &events,
        &control_events,
        WebSocketEventData::Opened { protocol },
        &cancellation,
    )
    .await
    {
        return;
    }
    let (mut writer, mut reader) = socket.split();
    loop {
        tokio::select! {
            biased;
            () = cancellation.cancelled() => {
                let _ = writer.close().await;
                return;
            }
            command = commands.recv() => {
                let Some(command) = command else {
                    let _ = writer.close().await;
                    return;
                };
                let (operation_id, messages) = match command {
                    WebSocketCommand::Send { operation_id, messages } => (operation_id, messages),
                    WebSocketCommand::Close { operation_id, code, reason } => {
                        let frame = match (code, reason.is_empty()) {
                            (None, true) => None,
                            (code, _) => Some(CloseFrame {
                                code: CloseCode::from(code.unwrap_or(1000)),
                                reason: reason.into(),
                            }),
                        };
                        (operation_id, vec![Message::Close(frame)])
                    }
                };
                for message in messages {
                    if let Err(error) = writer.send(message).await {
                        let _ = send_web_socket_event(
                            &state,
                            socket_id,
                            &events,
                            &control_events,
                            WebSocketEventData::Error(format!("Native WebSocket send failed: {error}")),
                            &cancellation,
                        ).await;
                        return;
                    }
                }
                if !send_web_socket_event(
                    &state,
                    socket_id,
                    &events,
                    &control_events,
                    WebSocketEventData::Sent { operation_id },
                    &cancellation,
                ).await {
                    return;
                }
            }
            incoming = reader.next() => {
                let event = match incoming {
                    Some(Ok(Message::Text(value))) => WebSocketEventData::Text(value.to_string()),
                    Some(Ok(Message::Binary(value))) => WebSocketEventData::Binary(value),
                    Some(Ok(Message::Close(frame))) => {
                        let (code, reason) = frame
                            .map(|frame| (Some(u16::from(frame.code)), frame.reason.to_string()))
                            .unwrap_or((None, String::new()));
                        let _ = send_web_socket_event(
                            &state,
                            socket_id,
                            &events,
                            &control_events,
                            WebSocketEventData::Closed { code, reason },
                            &cancellation,
                        ).await;
                        return;
                    }
                    Some(Ok(Message::Ping(value))) => {
                        if let Err(error) = writer.send(Message::Pong(value)).await {
                            let _ = send_web_socket_event(
                                &state,
                                socket_id,
                                &events,
                                &control_events,
                                WebSocketEventData::Error(format!(
                                    "Native WebSocket pong failed: {error}"
                                )),
                                &cancellation,
                            ).await;
                            return;
                        }
                        continue;
                    }
                    Some(Ok(Message::Pong(_))) | Some(Ok(Message::Frame(_))) => continue,
                    Some(Err(error)) => WebSocketEventData::Error(format!(
                        "Native WebSocket receive failed: {error}"
                    )),
                    None => WebSocketEventData::Closed {
                        code: None,
                        reason: String::new(),
                    },
                };
                let terminal = matches!(
                    event,
                    WebSocketEventData::Closed { .. } | WebSocketEventData::Error(_)
                );
                if !send_web_socket_event(
                    &state,
                    socket_id,
                    &events,
                    &control_events,
                    event,
                    &cancellation,
                ).await || terminal {
                    return;
                }
            }
        }
    }
}

fn prepare_web_socket_request(
    url: &str,
    headers: Vec<(String, String)>,
    protocols: Vec<String>,
) -> Result<tokio_tungstenite::tungstenite::http::Request<()>, String> {
    let mut request = url
        .into_client_request()
        .map_err(|error| format!("Invalid WebSocket URL: {error}"))?;
    for (name, value) in headers {
        let name = HeaderName::from_bytes(name.as_bytes())
            .map_err(|error| format!("Invalid WebSocket header name: {error}"))?;
        let value = HeaderValue::from_str(&value)
            .map_err(|error| format!("Invalid WebSocket header value: {error}"))?;
        request.headers_mut().insert(name, value);
    }
    if !protocols.is_empty() {
        request.headers_mut().insert(
            "sec-websocket-protocol",
            HeaderValue::from_str(&protocols.join(", "))
                .map_err(|error| format!("Invalid WebSocket protocols: {error}"))?,
        );
    }
    Ok(request)
}

async fn send_web_socket_event(
    state: &ClientState,
    socket_id: i64,
    events: &mpsc::Sender<WebSocketEventData>,
    control_events: &mpsc::UnboundedSender<WebSocketEventData>,
    event: WebSocketEventData,
    cancellation: &CancellationToken,
) -> bool {
    let kind = web_socket_event_kind(&event);
    let sent = if matches!(kind, WEBSOCKET_EVENT_TEXT | WEBSOCKET_EVENT_BINARY) {
        tokio::select! {
            () = cancellation.cancelled() => return false,
            result = events.send(event) => result.is_ok(),
        }
    } else {
        control_events.send(event).is_ok()
    };
    let notification = -((socket_id << 3) | i64::from(kind));
    sent && state.completion_port.post(notification)
}

const fn web_socket_event_kind(event: &WebSocketEventData) -> i32 {
    match event {
        WebSocketEventData::Opened { .. } => WEBSOCKET_EVENT_OPENED,
        WebSocketEventData::Text(_) => WEBSOCKET_EVENT_TEXT,
        WebSocketEventData::Binary(_) => WEBSOCKET_EVENT_BINARY,
        WebSocketEventData::Closed { .. } => WEBSOCKET_EVENT_CLOSED,
        WebSocketEventData::Error(_) => WEBSOCKET_EVENT_ERROR,
        WebSocketEventData::Sent { .. } => WEBSOCKET_EVENT_SENT,
    }
}

fn web_socket_event_to_ffi(socket_id: i64, event: WebSocketEventData) -> NativeWebSocketEvent {
    let mut value = NativeWebSocketEvent {
        kind: 0,
        socket_id,
        operation_id: 0,
        close_code: -1,
        text: ptr::null_mut(),
        binary_buffer: ptr::null_mut(),
    };
    match event {
        WebSocketEventData::Opened { protocol } => {
            value.kind = WEBSOCKET_EVENT_OPENED;
            if let Some(protocol) = protocol {
                value.text = c_string(protocol);
            }
        }
        WebSocketEventData::Text(text) => {
            value.kind = WEBSOCKET_EVENT_TEXT;
            value.text = c_string(text);
        }
        WebSocketEventData::Binary(bytes) => {
            value.kind = WEBSOCKET_EVENT_BINARY;
            value.binary_buffer = Box::into_raw(Box::new(web_socket_buffer(bytes))).cast();
        }
        WebSocketEventData::Closed { code, reason } => {
            value.kind = WEBSOCKET_EVENT_CLOSED;
            value.close_code = code.map(i32::from).unwrap_or(-1);
            if !reason.is_empty() {
                value.text = c_string(reason);
            }
        }
        WebSocketEventData::Error(error) => {
            value.kind = WEBSOCKET_EVENT_ERROR;
            value.text = c_string(error);
        }
        WebSocketEventData::Sent { operation_id } => {
            value.kind = WEBSOCKET_EVENT_SENT;
            value.operation_id = operation_id;
        }
    }
    value
}

fn web_socket_buffer(bytes: Bytes) -> NexBuffer {
    let context = Box::new(ResponseBufferContext { bytes });
    NexBuffer {
        abi_version: NEX_ABI_VERSION,
        struct_size: size_of::<NexBuffer>(),
        capabilities: NEX_CAPABILITY_THREAD_SAFE,
        ptr: context.bytes.as_ptr(),
        len: context.bytes.len(),
        context: Box::into_raw(context).cast(),
        release: Some(response_buffer_release),
    }
}

#[allow(clippy::too_many_arguments)]
unsafe fn prepare_request(
    state: &ClientState,
    method: *const c_char,
    url: *const c_char,
    headers: *const NativeHttpHeader,
    header_count: isize,
    body: *const u8,
    body_length: isize,
    native_body: *mut c_void,
    native_body_length: i64,
    native_prefix: *const u8,
    native_prefix_length: isize,
    native_suffix: *const u8,
    native_suffix_length: isize,
) -> Result<(reqwest::Request, Option<RequestStreamCancel>), String> {
    let method = Method::from_bytes(unsafe { required_c_str(method, "method")? }.as_bytes())
        .map_err(|error| format!("Invalid HTTP method: {error}"))?;
    let url = Url::parse(&unsafe { required_c_str(url, "URL")? })
        .map_err(|error| format!("Invalid HTTP URL: {error}"))?;
    let mut builder = state.client.request(method, url);
    for (name, value) in unsafe { read_headers(headers, header_count)? } {
        builder = builder.header(name, value);
    }

    let mut request = builder
        .build()
        .map_err(|error| format!("Could not build HTTP request: {error}"))?;
    let mut body_cancel = None;
    if !native_body.is_null() {
        let prefix = unsafe { copy_optional_bytes(native_prefix, native_prefix_length)? };
        let suffix = unsafe { copy_optional_bytes(native_suffix, native_suffix_length)? };
        let descriptor = unsafe { ptr::read(native_body.cast::<NexByteStream>()) };
        if descriptor.capabilities & NEX_CAPABILITY_CONCURRENT_CANCEL == 0
            || descriptor.cancel.is_none()
        {
            return Err("Native request body must support concurrent cancellation.".to_owned());
        }
        let stream = AdoptedRequestStream::adopt(descriptor)?;
        body_cancel = stream.cancel_handle();
        *request.body_mut() = Some(native_request_body(stream, prefix, suffix));
        if native_body_length >= 0 {
            request.headers_mut().insert(
                reqwest::header::CONTENT_LENGTH,
                native_body_length
                    .to_string()
                    .parse()
                    .expect("a non-negative integer is a valid header value"),
            );
        }
    } else if body_length > 0 {
        if body.is_null() {
            return Err("Missing HTTP request body bytes.".to_owned());
        }
        let bytes = unsafe { std::slice::from_raw_parts(body, body_length as usize) }.to_vec();
        *request.body_mut() = Some(Body::from(bytes));
    }
    Ok((request, body_cancel))
}

fn native_request_body(stream: AdoptedRequestStream, prefix: Vec<u8>, suffix: Vec<u8>) -> Body {
    let (sender, receiver) = mpsc::channel::<Result<Bytes, io::Error>>(1);
    RUNTIME.spawn_blocking(move || {
        if !prefix.is_empty() && sender.blocking_send(Ok(Bytes::from(prefix))).is_err() {
            return;
        }
        let reader = stream.reader();
        loop {
            match reader.read_next() {
                Ok(RequestStreamRead::Chunk(bytes)) => {
                    if !bytes.is_empty() && sender.blocking_send(Ok(bytes)).is_err() {
                        return;
                    }
                }
                Ok(RequestStreamRead::Done) => break,
                Err(error) => {
                    let _ = sender.blocking_send(Err(io::Error::other(error)));
                    return;
                }
            }
        }
        if !suffix.is_empty() {
            let _ = sender.blocking_send(Ok(Bytes::from(suffix)));
        }
    });
    Body::wrap_stream(ReceiverStream::new(receiver))
}

async fn send_request(
    client: Client,
    request: reqwest::Request,
    cancellation: CancellationToken,
) -> Result<ResponseData, String> {
    let response = client
        .execute(request)
        .await
        .map_err(|error| format!("Native HTTP request failed: {error}"))?;
    let status = i32::from(response.status().as_u16());
    let headers = response
        .headers()
        .iter()
        .map(|(name, value)| serde_json::json!([name.as_str(), value.to_str().unwrap_or_default()]))
        .collect::<Vec<_>>();
    let metadata_json = serde_json::json!({"headers": headers}).to_string();
    let body_stream = response_stream(response, cancellation);
    Ok(ResponseData {
        status,
        metadata_json,
        body_stream: Some(Box::into_raw(Box::new(body_stream)) as usize),
    })
}

fn response_stream(response: reqwest::Response, cancellation: CancellationToken) -> NexByteStream {
    let (sender, receiver) = mpsc::channel::<Result<Bytes, String>>(1);
    let stream_cancel = cancellation.clone();
    RUNTIME.spawn(async move {
        use futures_util::StreamExt;
        let mut body = response.bytes_stream();
        loop {
            tokio::select! {
                () = stream_cancel.cancelled() => return,
                item = body.next() => match item {
                    Some(Ok(bytes)) => {
                        if sender.send(Ok(bytes)).await.is_err() { return; }
                    }
                    Some(Err(error)) => {
                        let _ = sender.send(Err(format!("Native HTTP response failed: {error}"))).await;
                        return;
                    }
                    None => return,
                }
            }
        }
    });
    let context = Box::new(ResponseStreamContext {
        receiver: Mutex::new(receiver),
        cancellation,
        terminal: AtomicBool::new(false),
    });
    NexByteStream {
        abi_version: NEX_ABI_VERSION,
        struct_size: size_of::<NexByteStream>(),
        capabilities: NEX_CAPABILITY_THREAD_SAFE | NEX_CAPABILITY_CONCURRENT_CANCEL,
        context: Box::into_raw(context).cast(),
        next: Some(response_stream_next),
        cancel: Some(response_stream_cancel),
        release: Some(response_stream_release),
    }
}

struct ResponseStreamContext {
    receiver: Mutex<mpsc::Receiver<Result<Bytes, String>>>,
    cancellation: CancellationToken,
    terminal: AtomicBool,
}

struct ResponseBufferContext {
    bytes: Bytes,
}

unsafe extern "C" fn response_stream_next(
    context: *mut c_void,
    out_buffer: *mut NexBuffer,
    out_error: *mut NexUtf8View,
) -> i32 {
    let context = unsafe { &*context.cast::<ResponseStreamContext>() };
    if context.terminal.load(Ordering::Acquire) {
        return NEX_STREAM_READ_DONE;
    }
    let received = context
        .receiver
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .blocking_recv();
    match received {
        Some(Ok(bytes)) => {
            let buffer = Box::new(ResponseBufferContext { bytes });
            let descriptor = NexBuffer {
                abi_version: NEX_ABI_VERSION,
                struct_size: size_of::<NexBuffer>(),
                capabilities: NEX_CAPABILITY_THREAD_SAFE,
                ptr: buffer.bytes.as_ptr(),
                len: buffer.bytes.len(),
                context: Box::into_raw(buffer).cast(),
                release: Some(response_buffer_release),
            };
            unsafe { out_buffer.write(descriptor) };
            NEX_STREAM_READ_CHUNK
        }
        Some(Err(error)) => {
            context.terminal.store(true, Ordering::Release);
            if !out_error.is_null() {
                unsafe { out_error.write(NexUtf8View::from_utf8_str(&error)) };
            }
            NEX_STREAM_READ_ERROR
        }
        None => {
            context.terminal.store(true, Ordering::Release);
            if context.cancellation.is_cancelled() {
                NEX_STREAM_READ_CANCELED
            } else {
                NEX_STREAM_READ_DONE
            }
        }
    }
}

unsafe extern "C" fn response_stream_cancel(context: *mut c_void) {
    let context = unsafe { &*context.cast::<ResponseStreamContext>() };
    context.cancellation.cancel();
}

unsafe extern "C" fn response_stream_release(context: *mut c_void) {
    if !context.is_null() {
        unsafe { drop(Box::from_raw(context.cast::<ResponseStreamContext>())) };
    }
}

unsafe extern "C" fn response_buffer_release(context: *mut c_void) {
    if !context.is_null() {
        unsafe { drop(Box::from_raw(context.cast::<ResponseBufferContext>())) };
    }
}

fn release_buffer(buffer: NexBuffer) {
    if let Some(release) = buffer.release {
        unsafe { release(buffer.context) };
    }
}

fn copy_diagnostic(value: NexUtf8View) -> String {
    if !value.is_valid() || value.len == 0 {
        return "Native Exchange stream failed.".to_owned();
    }
    let bytes = unsafe { std::slice::from_raw_parts(value.ptr, value.len) };
    String::from_utf8_lossy(bytes).into_owned()
}

fn complete_request(state: &ClientState, request_id: i64, result: Result<ResponseData, String>) {
    if state.closed.load(Ordering::Acquire) {
        return;
    }
    if let Ok(mut tasks) = state.tasks.lock() {
        tasks.remove(&request_id);
    }
    if let Ok(mut results) = state.results.lock() {
        results.insert(request_id, result);
        state.completion_port.post(request_id);
    }
}

fn client_state(client_id: i64) -> Option<Arc<ClientState>> {
    CLIENTS
        .lock()
        .ok()
        .and_then(|clients| clients.get(&client_id).cloned())
}

unsafe fn read_headers(
    headers: *const NativeHttpHeader,
    count: isize,
) -> Result<Vec<(String, String)>, String> {
    if count < 0 || (count > 0 && headers.is_null()) {
        return Err("Invalid HTTP header entries.".to_owned());
    }
    if count == 0 {
        return Ok(Vec::new());
    }
    unsafe { std::slice::from_raw_parts(headers, count as usize) }
        .iter()
        .map(|header| {
            Ok((
                unsafe { required_c_str(header.name, "header name")? },
                unsafe { required_c_str(header.value, "header value")? },
            ))
        })
        .collect()
}

unsafe fn read_c_string_array(
    values: *const *const c_char,
    count: isize,
) -> Result<Vec<String>, String> {
    if count < 0 || (count > 0 && values.is_null()) {
        return Err("Invalid WebSocket protocol entries.".to_owned());
    }
    if count == 0 {
        return Ok(Vec::new());
    }
    unsafe { std::slice::from_raw_parts(values, count as usize) }
        .iter()
        .map(|value| unsafe { required_c_str(*value, "WebSocket protocol") })
        .collect()
}

unsafe fn required_c_str(value: *const c_char, name: &str) -> Result<String, String> {
    if value.is_null() {
        return Err(format!("Missing HTTP {name}."));
    }
    unsafe { CStr::from_ptr(value) }
        .to_str()
        .map(ToOwned::to_owned)
        .map_err(|error| format!("Invalid UTF-8 in HTTP {name}: {error}"))
}

unsafe fn copy_optional_bytes(value: *const u8, length: isize) -> Result<Vec<u8>, String> {
    if length < 0 || (length > 0 && value.is_null()) {
        return Err("Invalid native HTTP framing bytes.".to_owned());
    }
    if length == 0 {
        return Ok(Vec::new());
    }
    Ok(unsafe { std::slice::from_raw_parts(value, length as usize) }.to_vec())
}

fn positive_duration(milliseconds: i64) -> Option<Duration> {
    u64::try_from(milliseconds)
        .ok()
        .filter(|value| *value > 0)
        .map(Duration::from_millis)
}

fn bounded_capacity(value: isize) -> Option<usize> {
    usize::try_from(value)
        .ok()
        .filter(|value| (1..=1024).contains(value))
}

fn c_string(value: impl Into<String>) -> *mut c_char {
    CString::new(value.into())
        .unwrap_or_else(|_| CString::new("Native HTTP diagnostic contained a null byte.").unwrap())
        .into_raw()
}

unsafe fn free_c_string(value: *mut c_char) {
    if !value.is_null() {
        unsafe { drop(CString::from_raw(value)) };
    }
}

unsafe fn release_stream_pointer(pointer: *mut NexByteStream) {
    if pointer.is_null() {
        return;
    }
    let descriptor = unsafe { Box::from_raw(pointer) };
    if let Some(cancel) = descriptor.cancel {
        unsafe { cancel(descriptor.context) };
    }
    if let Some(release) = descriptor.release {
        unsafe { release(descriptor.context) };
    }
}

unsafe fn release_buffer_pointer(pointer: *mut NexBuffer) {
    if pointer.is_null() {
        return;
    }
    let descriptor = unsafe { *Box::from_raw(pointer) };
    release_buffer(descriptor);
}

#[derive(Clone, Copy)]
struct NativeCompletionPort(i64);

impl NativeCompletionPort {
    const fn new(port: i64) -> Self {
        Self(port)
    }

    fn post(self, request_id: i64) -> bool {
        let Some(api) = DART_API.get() else {
            return false;
        };
        unsafe { (api.post_integer)(self.0, request_id) }
    }
}

struct DartApi {
    post_integer: unsafe extern "C" fn(i64, i64) -> bool,
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

unsafe fn initialize_dart_api_dl(data: *mut c_void) -> Result<(), String> {
    if DART_API.get().is_some() {
        return Ok(());
    }
    if data.is_null() {
        return Err("Missing Dart API DL data.".to_owned());
    }
    let api = unsafe { &*(data.cast::<Api>()) };
    if api.major != 2 {
        return Err(format!(
            "Unsupported Dart API DL version {}.{}.",
            api.major, api.minor
        ));
    }
    let function = unsafe { api.lookup("Dart_PostInteger")? };
    DART_API
        .set(DartApi {
            post_integer: unsafe {
                std::mem::transmute::<*const c_void, unsafe extern "C" fn(i64, i64) -> bool>(
                    function,
                )
            },
        })
        .map_err(|_| "Dart API DL initialization raced.".to_owned())
}

impl Api {
    unsafe fn lookup(&self, name: &str) -> Result<*const c_void, String> {
        for index in 0..usize::MAX {
            let entry = unsafe { &*self.functions.add(index) };
            if entry.name.is_null() {
                break;
            }
            if unsafe { CStr::from_ptr(entry.name) }.to_string_lossy() == name {
                return Ok(entry.function);
            }
        }
        Err(format!("Dart API DL function {name} not found."))
    }
}
