#pragma once

#include <stdbool.h>
#include <stdint.h>

#if _WIN32
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FFI_PLUGIN_EXPORT
#endif

typedef struct CcQuicConfig CcQuicConfig;

enum {
  CC_QUIC_OK = 0,
  CC_QUIC_NULL_POINTER = 1,
  CC_QUIC_CONFIG_ERROR = 2,
  CC_QUIC_INVALID_ALPN = 3,
  CC_QUIC_CERT_LOAD_ERROR = 4,
  CC_QUIC_SOCKET_ERROR = 5,
  CC_QUIC_HANDSHAKE_ERROR = 6,
  CC_QUIC_EVENT_SEND_ERROR = 7,
  CC_QUIC_INTERNAL = 255,
};

FFI_PLUGIN_EXPORT int32_t cc_quic_init_dart_api(void* data);
FFI_PLUGIN_EXPORT int32_t cc_quic_init_logging(void);
FFI_PLUGIN_EXPORT const char* cc_quic_version(void);
FFI_PLUGIN_EXPORT int32_t cc_quic_config_new(CcQuicConfig** out_config);
FFI_PLUGIN_EXPORT void cc_quic_config_free(CcQuicConfig* config);
FFI_PLUGIN_EXPORT int32_t cc_quic_client_connect(
  CcQuicConfig* config,
  const char* host,
  uint16_t port,
  const char* server_name,
  const char* expected_server_fingerprint_hex,
  const char* cert_pem_path,
  const char* key_pem_path,
  int64_t dart_port,
  uint64_t* out_handle);
FFI_PLUGIN_EXPORT int32_t cc_quic_server_start(
  CcQuicConfig* config,
  const char* bind_addr,
  uint16_t port,
  const char* cert_pem_path,
  const char* key_pem_path,
  const char* trusted_fingerprints_csv,
  int64_t dart_port,
  uint64_t* out_handle);
FFI_PLUGIN_EXPORT int32_t cc_quic_conn_send(
  uint64_t handle,
  const uint8_t* conn_id,
  uintptr_t conn_id_len,
  const uint8_t* data,
  uintptr_t data_len);
FFI_PLUGIN_EXPORT int32_t cc_quic_conn_close(uint64_t handle);
