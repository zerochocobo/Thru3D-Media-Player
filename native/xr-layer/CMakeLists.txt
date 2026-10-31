add_library(quest_video_layer SHARED video_layer.cpp layer_extensions.cpp layer_copy.cpp browser_layer.cpp)
include("${CMAKE_CURRENT_LIST_DIR}/pip_shader.cmake")
target_include_directories(quest_video_layer PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
target_compile_features(quest_video_layer PRIVATE cxx_std_17)
target_compile_options(quest_video_layer PRIVATE -Wall -Wextra -Werror)
# Khronos headers only: Godot's own loader provides every function through xrGetInstanceProcAddr.
target_include_directories(quest_video_layer PRIVATE "${CMAKE_CURRENT_LIST_DIR}/../../third_party/openxr/include"
    "${CMAKE_CURRENT_LIST_DIR}/gdextension")
target_link_libraries(quest_video_layer PRIVATE GLESv3 EGL android log nativewindow)
target_link_options(quest_video_layer PRIVATE "-Wl,-z,max-page-size=16384")
