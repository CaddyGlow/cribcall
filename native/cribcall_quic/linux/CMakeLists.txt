# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

# Project-level configuration.
set(PROJECT_NAME "cribcall_quic")
project(${PROJECT_NAME} LANGUAGES CXX)

# Resolve through symlinks to find the repo root, then locate the shared
# cargokit directory at the root of the project.
get_filename_component(PLUGIN_ROOT "${CMAKE_CURRENT_LIST_DIR}/.." REALPATH)
get_filename_component(PROJECT_ROOT "${PLUGIN_ROOT}/../.." REALPATH)
set(CARGOKIT_DIR "${PROJECT_ROOT}/cargokit")

include("${CARGOKIT_DIR}/cmake/cargokit.cmake")
apply_cargokit(${PROJECT_NAME} ../rust cribcall_quic "")

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(cribcall_quic_bundled_libraries
  "${${PROJECT_NAME}_cargokit_lib}"
  PARENT_SCOPE
)
