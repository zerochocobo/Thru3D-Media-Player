cmake_minimum_required(VERSION 3.22)
project(QuestRvm LANGUAGES CXX)
# Shared JNI names are loaded explicitly from Kotlin/Godot. Dependencies must
# not add a Debug suffix, including when reconfiguring an existing build cache.
set(CMAKE_DEBUG_POSTFIX "" CACHE STRING "Keep Android JNI library names constant" FORCE)
find_package(ncnn CONFIG REQUIRED)
set(RVM_PROFILE_INCLUDE "${CMAKE_CURRENT_LIST_DIR}/../../build/rvm/include")
if(NOT EXISTS "${RVM_PROFILE_INCLUDE}/rvm_profiles.generated.h")
    message(FATAL_ERROR "Run tools/models/Prepare-RvmCandidate.ps1 before configuring the Android backend")
endif()
if(NOT MNN_SOURCE OR NOT EXISTS "${MNN_SOURCE}/include/MNN/Interpreter.hpp" OR NOT EXISTS "${MNN_LIB}")
    message(FATAL_ERROR "Pass -DMNN_SOURCE and -DMNN_LIB (run tools/Build-MnnAndroid.sh)")
endif()
# An old OpenCL-only archive links successfully but makes the fallback unusable.
execute_process(COMMAND "${CMAKE_NM}" --defined-only --extern-only "${MNN_LIB}"
    RESULT_VARIABLE mnn_symbols_status OUTPUT_VARIABLE mnn_symbols ERROR_VARIABLE mnn_symbols_error)
if(NOT mnn_symbols_status EQUAL 0 OR NOT mnn_symbols MATCHES "VulkanRuntime")
    message(FATAL_ERROR "MNN archive lacks Vulkan: rebuild with tools/Build-MnnAndroid.sh")
endif()
unset(mnn_symbols)
add_library(quest_rvm SHARED rvm_backend.cpp rvm_channel_mean.cpp rvm_identity_tile.cpp rvm_state_guard.cpp rvm_benchmark_jni.cpp
    rvm_runtime_jni.cpp rvm_mnn_backend.cpp mnn_rvm_graph.cpp depth_runtime_jni.cpp depth_stabilizer.cpp photo_depth.cpp media_delete.cpp
    # Scene import (experimental): Unity scene bundle unpacker and ETC2 texture encoder.
    ../unity-scene/unity_scene.cpp ../unity-scene/etc2_encoder.cpp ../unity-scene/unity_scene_jni.cpp)
target_compile_features(quest_rvm PRIVATE cxx_std_17)
target_compile_definitions(quest_rvm PRIVATE QUEST_DIAGNOSTIC_MODELS=$<BOOL:${QUEST_DIAGNOSTIC_MODELS}>)
target_include_directories(quest_rvm PRIVATE "${RVM_PROFILE_INCLUDE}")
target_include_directories(quest_rvm SYSTEM PRIVATE "${MNN_SOURCE}/include")
target_include_directories(quest_rvm SYSTEM PRIVATE "${MNN_SOURCE}/schema/current" "${MNN_SOURCE}/3rd_party/flatbuffers/include")
target_compile_options(quest_rvm PRIVATE -Wall -Wextra -Werror)
# Debug remains debuggable but must exercise the optimized production wrapper.
# Keep finite-value rejection valid; ncnn's separately built library is unchanged.
target_compile_options(quest_rvm PRIVATE "$<$<CONFIG:Debug>:-O2>" -fno-fast-math)
# The ncnn package exports -fno-exceptions for its own build. This JNI wrapper
# catches its validation errors; source options take precedence over that interface.
set_source_files_properties(rvm_backend.cpp rvm_channel_mean.cpp rvm_identity_tile.cpp rvm_state_guard.cpp rvm_benchmark_jni.cpp rvm_runtime_jni.cpp
    rvm_mnn_backend.cpp mnn_rvm_graph.cpp depth_runtime_jni.cpp depth_stabilizer.cpp photo_depth.cpp
    ../unity-scene/unity_scene.cpp ../unity-scene/etc2_encoder.cpp ../unity-scene/unity_scene_jni.cpp PROPERTIES COMPILE_OPTIONS "-fexceptions")
# MNN registers its OpenCL backend from static initializers; keep every object.
target_link_libraries(quest_rvm PRIVATE ncnn -Wl,--whole-archive "${MNN_LIB}" -Wl,--no-whole-archive log android dl nativewindow)
target_link_options(quest_rvm PRIVATE "-Wl,-z,max-page-size=16384")
add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../render-bridge" "render-bridge")
add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../mpv" "mpv")
add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../tiff" "tiff")
add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../hdr" "hdr")
add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../image" "image")
# Offline narration is a normal Debug and Release playback feature.
if(QUEST_NARRATION_ENABLED)
    add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../narration" "narration")
endif()
add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../xr-layer" "xr-layer")
add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../usb" "usb")
add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../airplay" "airplay")
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    # Standalone diagnostic target, never packaged in the library/APK.
    add_executable(photo_depth_probe EXCLUDE_FROM_ALL ../../tests/native/photo_depth_probe.cpp photo_depth.cpp depth_stabilizer.cpp)
    target_compile_features(photo_depth_probe PRIVATE cxx_std_17)
    target_include_directories(photo_depth_probe SYSTEM PRIVATE "${MNN_SOURCE}/include")
    target_compile_options(photo_depth_probe PRIVATE -O2 -fexceptions -fno-fast-math -Wall -Wextra -Werror)
    target_link_libraries(photo_depth_probe PRIVATE -Wl,--whole-archive "${MNN_LIB}" -Wl,--no-whole-archive log android dl nativewindow)
    target_sources(quest_rvm PRIVATE rvm_resident_validation.cpp rvm_resident_validation_jni.cpp)
    set_source_files_properties(rvm_resident_validation.cpp rvm_resident_validation_jni.cpp PROPERTIES COMPILE_OPTIONS "-fexceptions")
endif()
