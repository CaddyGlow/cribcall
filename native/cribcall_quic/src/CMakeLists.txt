# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(cribcall_quic_library VERSION 0.0.1 LANGUAGES C)

add_library(cribcall_quic SHARED
  "cribcall_quic.c"
)

set_target_properties(cribcall_quic PROPERTIES
  PUBLIC_HEADER cribcall_quic.h
  OUTPUT_NAME "cribcall_quic"
)

target_compile_definitions(cribcall_quic PUBLIC DART_SHARED_LIB)

if (ANDROID)
  # Support Android 15 16k page size
  target_link_options(cribcall_quic PRIVATE "-Wl,-z,max-page-size=16384")
endif()
