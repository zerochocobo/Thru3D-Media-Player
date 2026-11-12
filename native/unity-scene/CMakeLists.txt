cmake_minimum_required(VERSION 3.22)
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    project(ThruUnityScene LANGUAGES CXX)
endif()
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

add_library(thru_unity_scene STATIC unity_scene.cpp etc2_encoder.cpp)
target_include_directories(thru_unity_scene PUBLIC "${CMAKE_CURRENT_LIST_DIR}")
if(MSVC)
    target_compile_options(thru_unity_scene PRIVATE /W4 /WX /EHsc /utf-8)
else()
    target_compile_options(thru_unity_scene PRIVATE -Wall -Wextra -Werror -fexceptions)
endif()

# Command-line front end: the desktop tool, and on Android a way to time unpacking over adb
# without touching the installed player.
add_executable(unity_scene_unpack unity_scene_tool.cpp)
target_link_libraries(unity_scene_unpack PRIVATE thru_unity_scene)
if(ANDROID)
    # The player plugin compiles these sources into libquest_rvm; this target is a standalone check.
    add_library(thru_unity_scene_jni SHARED unity_scene_jni.cpp)
    target_link_libraries(thru_unity_scene_jni PRIVATE thru_unity_scene)
endif()
