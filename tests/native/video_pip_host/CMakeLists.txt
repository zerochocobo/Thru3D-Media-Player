cmake_minimum_required(VERSION 3.22)
project(video_pip_host LANGUAGES CXX)

# Run the production JNI draw with real GLES and a JNI-array fixture. OpenXR
# acquisition is replaced by an already-acquired ordinary texture.
set(VIDEO_LAYER_SOURCE "${CMAKE_CURRENT_LIST_DIR}/../../../native/xr-layer/video_layer.cpp" CACHE FILEPATH "Production source, or an earlier revision for a negative control")
set(PIP_HOST_HEADERS "" CACHE PATH "Optional host-compatible EGL/GLES/JNI headers")
set(PIP_HOST_GLES_DIR "" CACHE PATH "Optional GLES runtime library directory")
include("${CMAKE_CURRENT_LIST_DIR}/../../../native/xr-layer/pip_shader.cmake")
find_library(EGL_LIBRARY NAMES EGL libEGL.so.1 REQUIRED)
find_library(GLES_LIBRARY NAMES GLESv2 libGLESv2.so.2 HINTS "${PIP_HOST_GLES_DIR}" REQUIRED)
add_executable(video_pip_host main.cpp)
target_compile_features(video_pip_host PRIVATE cxx_std_17)
target_compile_definitions(video_pip_host PRIVATE VIDEO_LAYER_SOURCE="${VIDEO_LAYER_SOURCE}")
target_include_directories(video_pip_host PRIVATE "${CMAKE_CURRENT_LIST_DIR}" "${PIP_HOST_HEADERS}"
    "${CMAKE_CURRENT_BINARY_DIR}" "${CMAKE_CURRENT_LIST_DIR}/../../../native/xr-layer"
    "${CMAKE_CURRENT_LIST_DIR}/../../../third_party/openxr/include")
target_compile_options(video_pip_host PRIVATE -Wall -Wextra -g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer)
target_link_options(video_pip_host PRIVATE -fsanitize=address,undefined)
target_link_libraries(video_pip_host PRIVATE "${EGL_LIBRARY}" "${GLES_LIBRARY}")
enable_testing()
add_test(NAME video_pip_host COMMAND video_pip_host)
set_tests_properties(video_pip_host PROPERTIES ENVIRONMENT "EGL_PLATFORM=surfaceless;LIBGL_ALWAYS_SOFTWARE=1;ASAN_OPTIONS=detect_leaks=0;UBSAN_OPTIONS=halt_on_error=1")
