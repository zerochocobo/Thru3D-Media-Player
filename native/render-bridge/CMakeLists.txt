add_library(quest_render_bridge SHARED render_bridge.cpp)
target_compile_features(quest_render_bridge PRIVATE cxx_std_17)
target_compile_options(quest_render_bridge PRIVATE -Wall -Wextra -Werror)
# Debug stays debuggable but runs the production speed: the bridge works on the render thread
# (per-frame copies, the video near-map limit: 6.0 ms at -O0, 0.4 ms at -O2 on Quest 3).
target_compile_options(quest_render_bridge PRIVATE "$<$<CONFIG:Debug>:-O2>")
target_link_libraries(quest_render_bridge PRIVATE GLESv3 EGL android log nativewindow)
target_link_options(quest_render_bridge PRIVATE "-Wl,-z,max-page-size=16384")
