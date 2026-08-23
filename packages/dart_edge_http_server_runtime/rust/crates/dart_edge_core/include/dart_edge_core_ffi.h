#ifndef DART_EDGE_CORE_FFI_H_
#define DART_EDGE_CORE_FFI_H_

#include <stddef.h>
#include <stdint.h>

typedef struct NativeBytes {
  const uint8_t* ptr;
  intptr_t len;
} NativeBytes;

typedef struct NativeOwnedBytes {
  uint8_t* ptr;
  intptr_t len;
} NativeOwnedBytes;

typedef struct NativeString {
  NativeBytes bytes;
} NativeString;

typedef struct NativePair {
  NativeBytes key;
  NativeBytes value;
} NativePair;

typedef int32_t NativeStatus;

#define NativeStatusOk 0
#define NativeStatusError 1

typedef struct NativeResult {
  NativeStatus status;
  NativeBytes code;
  NativeBytes message;
} NativeResult;

#define NATIVE_BYTE_STREAM_ABI_VERSION 1
#define NATIVE_BYTE_STREAM_READ_CHUNK 0
#define NATIVE_BYTE_STREAM_READ_DONE 1
#define NATIVE_BYTE_STREAM_READ_ERROR 2
#define NATIVE_BYTE_STREAM_READ_CANCELED 3

typedef struct NativeByteStreamRead {
  int32_t status;
  NativeOwnedBytes bytes;
  NativeBytes error;
} NativeByteStreamRead;

typedef NativeByteStreamRead* (*NativeByteStreamNext)(void* context);
typedef void (*NativeByteStreamCancel)(void* context);
typedef void (*NativeByteStreamFreeRead)(NativeByteStreamRead* value);
typedef void (*NativeByteStreamRelease)(void* context);

typedef struct NativeByteStream {
  uint32_t abi_version;
  size_t struct_size;
  void* context;
  NativeByteStreamNext next;
  NativeByteStreamCancel cancel;
  NativeByteStreamFreeRead free_read;
  NativeByteStreamRelease release;
} NativeByteStream;

#endif  // DART_EDGE_CORE_FFI_H_
