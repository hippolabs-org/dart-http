#ifndef DART_HTTP_CORE_FFI_H_
#define DART_HTTP_CORE_FFI_H_

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

#endif  // DART_HTTP_CORE_FFI_H_
