cmake_minimum_required(VERSION 3.10)
project(rust_lib_zanzibarr LANGUAGES NONE)

# flutter-webos installs this prebuilt engine into bundle/lib and sets the
# runner RPATH to $ORIGIN/lib. Build tools place the target-specific .so here.
set(rust_lib_zanzibarr_bundled_libraries
  "${CMAKE_CURRENT_SOURCE_DIR}/lib/librust_lib_zanzibarr.so"
  PARENT_SCOPE
)
