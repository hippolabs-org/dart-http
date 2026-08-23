#ifndef DART_EDGE_HTTP_SERVER_RUNTIME_H_
#define DART_EDGE_HTTP_SERVER_RUNTIME_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <dart_edge_core_ffi.h>
#include <dart_edge_http_server_core.h>

typedef void (*dart_edge_http_server_runtime_transport_event_callback_t)(
    int32_t event_kind,
    int64_t event_id);

typedef struct NativeTransportRequest {
  NativeBytes route_id;
  intptr_t path_param_count;
  const NativePair* path_params;
  intptr_t query_count;
  const NativePair* query;
  intptr_t header_count;
  const NativePair* headers;
  NativeBytes body;
  uint8_t request_kind;
  uint8_t body_kind;
} NativeTransportRequest;

typedef struct NativeWebSocketConnection {
  int64_t session_id;
  int64_t request_id;
  NativeBytes route_id;
  intptr_t path_param_count;
  const NativePair* path_params;
  intptr_t query_count;
  const NativePair* query;
  intptr_t header_count;
  const NativePair* headers;
} NativeWebSocketConnection;

typedef struct NativeWebSocketMessage {
  int64_t session_id;
  uint8_t kind;
  NativeBytes body;
} NativeWebSocketMessage;

typedef struct NativeWebTransportConnection {
  int64_t session_id;
  int64_t request_id;
  NativeBytes route_id;
  intptr_t path_param_count;
  const NativePair* path_params;
  intptr_t query_count;
  const NativePair* query;
  intptr_t header_count;
  const NativePair* headers;
} NativeWebTransportConnection;

typedef struct NativeWebTransportDatagram {
  int64_t session_id;
  NativeBytes body;
} NativeWebTransportDatagram;

typedef struct NativeWebTransportStream {
  int64_t session_id;
  NativeBytes body;
} NativeWebTransportStream;

typedef struct NativeWebTransportStreamInfo {
  int64_t session_id;
  int64_t stream_id;
  int64_t protocol_id;
  uint8_t kind;
} NativeWebTransportStreamInfo;

typedef struct NativeWebTransportStreamChunk {
  int64_t stream_id;
  NativeBytes body;
} NativeWebTransportStreamChunk;

typedef struct NativeWebTransportStreamTerminal {
  int64_t stream_id;
  int64_t error_code;
  NativeBytes error;
} NativeWebTransportStreamTerminal;

typedef struct NativeWebTransportOperation {
  int64_t operation_id;
  int64_t session_id;
  int64_t stream_id;
  int64_t protocol_id;
  uint8_t kind;
  bool succeeded;
  NativeBytes error;
} NativeWebTransportOperation;

typedef struct NativeMultipartField {
  NativeBytes name;
  NativeBytes value;
} NativeMultipartField;

typedef struct NativeMultipartFile {
  NativeBytes field_name;
  NativeBytes filename;
  NativeBytes content_type;
  NativeBytes body;
} NativeMultipartFile;

typedef struct NativeMultipartForm {
  intptr_t field_count;
  const NativeMultipartField* fields;
  intptr_t file_count;
  const NativeMultipartFile* files;
} NativeMultipartForm;

int32_t dart_edge_http_server_runtime_native_abi_version(void);

int64_t dart_edge_http_server_runtime_start_server(
    const char* host,
    int64_t port,
    int64_t worker_count,
    const char* routes_json,
    const char* middlewares_json,
    dart_edge_http_server_runtime_transport_event_callback_t callback);

void dart_edge_http_server_runtime_stop_server(void);

void dart_edge_http_server_runtime_stop_server_by_id(int64_t server_id);

NativeTransportRequest* dart_edge_http_server_runtime_take_request(int64_t request_id);

void dart_edge_http_server_runtime_free_request(NativeTransportRequest* value);

bool dart_edge_http_server_runtime_accept_web_socket(
    int64_t request_id,
    intptr_t header_count,
    const NativePair* headers);

bool dart_edge_http_server_runtime_accept_web_transport(
    int64_t request_id,
    intptr_t header_count,
    const NativePair* headers);

bool dart_edge_http_server_runtime_start_sse_response(
    int64_t request_id,
    int32_t status,
    intptr_t header_count,
    const NativePair* headers);

bool dart_edge_http_server_runtime_send_sse_chunk(
    int64_t request_id,
    const char* chunk);

bool dart_edge_http_server_runtime_finish_sse_response(int64_t request_id);

bool dart_edge_http_server_runtime_start_binary_stream_response(
    int64_t request_id,
    int32_t status,
    const char* content_type,
    int64_t content_length,
    intptr_t header_count,
    const NativePair* headers);

bool dart_edge_http_server_runtime_send_binary_stream_chunk(
    int64_t request_id,
    NativeBytes chunk);

bool dart_edge_http_server_runtime_finish_binary_stream_response(
    int64_t request_id);

bool dart_edge_http_server_runtime_start_native_binary_stream_response(
    int64_t request_id,
    int32_t status,
    const char* content_type,
    int64_t content_length,
    intptr_t header_count,
    const NativePair* headers,
    const NativeByteStream* stream);

NativeMultipartForm* dart_edge_http_server_runtime_parse_multipart(
    NativeTransportRequest* request,
    const char* content_type);

void dart_edge_http_server_runtime_free_multipart_form(NativeMultipartForm* value);

NativeWebSocketConnection* dart_edge_http_server_runtime_take_web_socket_connection(
    int64_t session_id);

void dart_edge_http_server_runtime_free_web_socket_connection(
    NativeWebSocketConnection* value);

NativeWebSocketMessage* dart_edge_http_server_runtime_take_web_socket_message(
    int64_t session_id);

void dart_edge_http_server_runtime_free_web_socket_message(
    NativeWebSocketMessage* value);

NativeWebTransportConnection* dart_edge_http_server_runtime_take_web_transport_connection(
    int64_t session_id);

void dart_edge_http_server_runtime_free_web_transport_connection(
    NativeWebTransportConnection* value);

NativeWebTransportDatagram* dart_edge_http_server_runtime_take_web_transport_datagram(
    int64_t session_id);

void dart_edge_http_server_runtime_free_web_transport_datagram(
    NativeWebTransportDatagram* value);

NativeWebTransportStream* dart_edge_http_server_runtime_take_web_transport_stream(
    int64_t session_id);

void dart_edge_http_server_runtime_free_web_transport_stream(
    NativeWebTransportStream* value);

NativeWebTransportStreamInfo* dart_edge_http_server_runtime_take_web_transport_stream_info(
    int64_t stream_id);

void dart_edge_http_server_runtime_free_web_transport_stream_info(
    NativeWebTransportStreamInfo* value);

NativeWebTransportStreamChunk* dart_edge_http_server_runtime_take_web_transport_stream_chunk(
    int64_t stream_id);

void dart_edge_http_server_runtime_free_web_transport_stream_chunk(
    NativeWebTransportStreamChunk* value);

NativeWebTransportStreamTerminal* dart_edge_http_server_runtime_take_web_transport_stream_terminal(
    int64_t stream_id);

void dart_edge_http_server_runtime_free_web_transport_stream_terminal(
    NativeWebTransportStreamTerminal* value);

NativeWebTransportOperation* dart_edge_http_server_runtime_take_web_transport_operation(
    int64_t operation_id);

void dart_edge_http_server_runtime_free_web_transport_operation(
    NativeWebTransportOperation* value);

int64_t dart_edge_http_server_runtime_web_transport_open_unidirectional_stream(
    int64_t session_id);

int64_t dart_edge_http_server_runtime_web_transport_open_bidirectional_stream(
    int64_t session_id);

int64_t dart_edge_http_server_runtime_web_transport_stream_write(
    int64_t stream_id,
    NativeBytes body);

int64_t dart_edge_http_server_runtime_web_transport_stream_finish(
    int64_t stream_id);

int64_t dart_edge_http_server_runtime_web_transport_stream_reset(
    int64_t stream_id,
    uint32_t error_code);

int64_t dart_edge_http_server_runtime_web_transport_stream_stop(
    int64_t stream_id,
    uint32_t error_code);

bool dart_edge_http_server_runtime_web_transport_send_datagram(
    int64_t session_id,
    NativeBytes body);

bool dart_edge_http_server_runtime_web_transport_send_stream(
    int64_t session_id,
    NativeBytes body);

bool dart_edge_http_server_runtime_web_transport_close(
    int64_t session_id,
    int32_t code,
    const char* reason);

bool dart_edge_http_server_runtime_web_socket_send_text(
    int64_t session_id,
    const char* text);

bool dart_edge_http_server_runtime_web_socket_send_binary(
    int64_t session_id,
    NativeBytes body);

bool dart_edge_http_server_runtime_web_socket_close(
    int64_t session_id,
    int32_t code,
    const char* reason);

char* dart_edge_http_server_runtime_take_last_error(void);

void dart_edge_http_server_runtime_free_string(char* value);

bool dart_edge_http_server_runtime_send_response(
    int64_t request_id,
    int32_t status,
    const char* content_type,
    NativeBytes body,
    intptr_t header_count,
    const NativePair* headers);

#endif  // DART_EDGE_HTTP_SERVER_RUNTIME_H_
