#ifndef DART_HTTP_NATIVE_CLIENT_H_
#define DART_HTTP_NATIVE_CLIENT_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct NativeHttpHeader {
  const char* name;
  const char* value;
} NativeHttpHeader;

typedef struct NativeHttpResult {
  bool success;
  int32_t status_code;
  char* metadata_json;
  void* body_stream;
  char* error;
} NativeHttpResult;

typedef struct NativeWebSocketEvent {
  int32_t kind;
  int64_t socket_id;
  int64_t operation_id;
  int32_t close_code;
  char* text;
  void* binary_buffer;
} NativeWebSocketEvent;

int32_t dart_http_native_client_initialize_api_dl(void* data);
int32_t dart_http_native_client_abi_version(void);
int64_t dart_http_native_client_create(
    int64_t completion_port,
    int64_t connect_timeout_ms,
    int64_t request_timeout_ms);
void dart_http_native_client_close(int64_t client_id);
int64_t dart_http_native_client_start(
    int64_t client_id,
    const char* method,
    const char* url,
    const NativeHttpHeader* headers,
    intptr_t header_count,
    const uint8_t* body,
    intptr_t body_length,
    void* native_body,
    int64_t native_body_length,
    const uint8_t* native_prefix,
    intptr_t native_prefix_length,
    const uint8_t* native_suffix,
    intptr_t native_suffix_length);
bool dart_http_native_client_cancel(int64_t client_id, int64_t request_id);
NativeHttpResult* dart_http_native_client_take_result(
    int64_t client_id,
    int64_t request_id);
void dart_http_native_client_free_result(NativeHttpResult* result);

int64_t dart_http_native_client_websocket_connect(
    int64_t client_id,
    const char* url,
    const NativeHttpHeader* headers,
    intptr_t header_count,
    const char* const* protocols,
    intptr_t protocol_count,
    intptr_t incoming_capacity,
    intptr_t outgoing_capacity);
int64_t dart_http_native_client_websocket_send_text(
    int64_t client_id,
    int64_t socket_id,
    const char* value);
int64_t dart_http_native_client_websocket_send_binary(
    int64_t client_id,
    int64_t socket_id,
    const uint8_t* value,
    intptr_t length);
int64_t dart_http_native_client_websocket_send_binary_native_prefixed(
    int64_t client_id,
    int64_t socket_id,
    const uint8_t* prefix,
    intptr_t prefix_length,
    void* native_buffer);
int64_t dart_http_native_client_websocket_close(
    int64_t client_id,
    int64_t socket_id,
    int32_t code,
    const char* reason);
bool dart_http_native_client_websocket_abort(
    int64_t client_id,
    int64_t socket_id);
NativeWebSocketEvent* dart_http_native_client_websocket_take_event(
    int64_t client_id,
    int64_t socket_id,
    int32_t kind);
bool dart_http_native_client_websocket_event_take_binary(
    NativeWebSocketEvent* event,
    void* out_buffer);
void dart_http_native_client_websocket_free_event(
    NativeWebSocketEvent* event);

#endif
