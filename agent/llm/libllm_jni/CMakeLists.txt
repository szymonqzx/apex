# cmake_minimum_required(VERSION 3.18)
# CMakeLists.txt — Standalone CMake build for libllm_jni
#
# Used when building outside the AOSP/LineageOS tree (e.g., NDK standalone).
# Inside the AOSP tree, use Android.bp instead.

cmake_minimum_required(VERSION 3.18)
project(llm_jni C)

set(CMAKE_C_STANDARD 11)

# NDK toolchain handles ABI; this file is for standalone NDK builds.
# Usage:
#   cmake -B build \
#     -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake \
#     -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-28
#   cmake --build build

# llama.cpp include path — set to your llama.cpp source/include
if(NOT DEFINED LLAMA_INCLUDE_DIR)
  set(LLAMA_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../llama.cpp/include")
endif()

if(NOT DEFINED LLAMA_LIB_DIR)
  set(LLAMA_LIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../out/arm64")
endif()

include_directories(
  ${LLAMA_INCLUDE_DIR}
  ${ANDROID_NDK_HOME}/sysroot/usr/include
  ${ANDROID_NDK_HOME}/sysroot/usr/include/aarch64-linux-android
)

add_library(llm_jni SHARED llm_jni.c)

target_link_libraries(llm_jni
  ${LLAMA_LIB_DIR}/libllama.so
  log
  dl
)

target_compile_options(llm_jni PRIVATE
  -O3
  -fPIC
  -Wall
  -Wextra
)
