# the minimum version of CMake.
cmake_minimum_required(VERSION 3.4.1)
project(MihomoPocNative)

set(NATIVE_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(
    ${NATIVE_ROOT_PATH}
)

find_library(hilog-lib hilog_ndk.z)

add_library(poc_napi SHARED poc_napi.cpp)

target_link_libraries(poc_napi PUBLIC
    ${hilog-lib}
    libace_napi.z.so
    libdl.a
    libc++.a
)
