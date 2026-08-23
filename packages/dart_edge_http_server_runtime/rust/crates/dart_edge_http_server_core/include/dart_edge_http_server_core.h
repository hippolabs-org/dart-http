#ifndef DART_EDGE_HTTP_SERVER_CORE_H_
#define DART_EDGE_HTTP_SERVER_CORE_H_

#include <stdint.h>

#include <dart_edge_core_ffi.h>

#define DART_EDGE_NATIVE_HTTP_METHOD_GET 0
#define DART_EDGE_NATIVE_HTTP_METHOD_POST 1
#define DART_EDGE_NATIVE_HTTP_METHOD_PUT 2
#define DART_EDGE_NATIVE_HTTP_METHOD_PATCH 3
#define DART_EDGE_NATIVE_HTTP_METHOD_DELETE 4
#define DART_EDGE_NATIVE_HTTP_METHOD_HEAD 5
#define DART_EDGE_NATIVE_HTTP_METHOD_OPTIONS 6

typedef struct NativeHttpResponse {
  uint16_t status;
  NativeBytes content_type;
  intptr_t header_count;
  const NativePair* headers;
  NativeBytes body;
} NativeHttpResponse;

typedef struct NativeHttpRequest {
  int32_t method;
  const char* path;
  intptr_t query_count;
  const NativePair* query;
  intptr_t header_count;
  const NativePair* headers;
  NativeBytes body;
} NativeHttpRequest;

typedef NativeHttpResponse* (*dart_edge_native_http_handler_t)(
    int64_t handle,
    const NativeHttpRequest* request);

typedef void (*dart_edge_native_http_free_response_t)(NativeHttpResponse* value);

#endif  // DART_EDGE_HTTP_SERVER_CORE_H_
