cmake_minimum_required(VERSION 3.20)
project(native_db
    VERSION 0.1.1
    DESCRIPTION "C wrapper over libpq with Dart Native Ports for async I/O"
    LANGUAGES C
)

# This tree builds ONE library and links ONE client library. There is
# deliberately no mysql_config, no find_package(SQLite3) and no pkg-config for
# libmongoc here, and adding one would be a regression the build checks exist
# to catch.
#
# ABI:      native_db.h

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

find_package(Threads REQUIRED)

# Help find_package(PostgreSQL) locate Homebrew libpq on macOS, which is keg-only.
if(APPLE AND NOT DEFINED PostgreSQL_ROOT)
    foreach(_candidate "/opt/homebrew/opt/libpq" "/usr/local/opt/libpq")
        if(EXISTS "${_candidate}/include/libpq-fe.h")
            set(PostgreSQL_ROOT "${_candidate}" CACHE PATH "Homebrew libpq prefix" FORCE)
            message(STATUS "Detected Homebrew libpq at ${PostgreSQL_ROOT}")
            break()
        endif()
    endforeach()
endif()

find_package(PostgreSQL REQUIRED)

add_library(native_db SHARED
    src/native_db.c
    src/native_pool.c
    src/native_pool_worker.c
    src/dart_api_dl.c
)

target_include_directories(native_db
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/include
        # dart_api_dl.c (vendored, do not modify) does `#include "dart_api_dl.h"`
        # without the dart/ prefix; expose include/dart/ directly:
        ${CMAKE_CURRENT_SOURCE_DIR}/include/dart
        ${PostgreSQL_INCLUDE_DIRS}
)

target_link_libraries(native_db
    PRIVATE
        ${PostgreSQL_LIBRARIES}
        Threads::Threads
)

target_compile_options(native_db PRIVATE
    -Wall -Wextra -Wpedantic
)

# Expose POSIX `clock_gettime` / `CLOCK_REALTIME` on Linux glibc
# (visible by default on macOS, but glibc gates them behind a
# feature-test macro). 200809L = POSIX.1-2008.
target_compile_definitions(native_db PRIVATE
    _POSIX_C_SOURCE=200809L
)

# Produces:
#   - libnative_db.dylib (macOS)
#   - libnative_db.so    (Linux)
#   - native_db.dll      (Windows)
# Loaded at runtime by dart/lib/src/native_lib_loader.dart.
# Produces:
#   - libnative_db.dylib (macOS)
#   - libnative_db.so    (Linux)
# Loaded at runtime by lib/src/native/postgres_lib_loader.dart.
