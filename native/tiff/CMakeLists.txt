cmake_minimum_required(VERSION 3.22)
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    project(ThruTiff LANGUAGES C CXX)
endif()
include(FetchContent)
include(ExternalProject)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(ENABLE_SHARED OFF CACHE BOOL "" FORCE)
set(ENABLE_STATIC ON CACHE BOOL "" FORCE)
set(WITH_TURBOJPEG OFF CACHE BOOL "" FORCE)
set(WITH_TOOLS OFF CACHE BOOL "" FORCE)
set(WITH_TESTS OFF CACHE BOOL "" FORCE)
set(WITH_SIMD OFF CACHE BOOL "" FORCE)
FetchContent_Declare(thru_jpeg URL "${CMAKE_CURRENT_LIST_DIR}/../../third_party/tiff/libjpeg-turbo-3.1.2.tar.gz"
    URL_HASH SHA256=560f6338b547544c4f9721b18d8b87685d433ec78b3c644c70d77adad22c55e6
    SOURCE_SUBDIR _external_project_only
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_MakeAvailable(thru_jpeg)
file(MAKE_DIRECTORY "${thru_jpeg_BINARY_DIR}")
ExternalProject_Add(thru_jpeg_build SOURCE_DIR "${thru_jpeg_SOURCE_DIR}" BINARY_DIR "${thru_jpeg_BINARY_DIR}"
    CMAKE_ARGS "-DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE}" "-DANDROID_ABI=${ANDROID_ABI}"
        "-DANDROID_PLATFORM=${ANDROID_PLATFORM}" "-DCMAKE_MAKE_PROGRAM=${CMAKE_MAKE_PROGRAM}"
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DENABLE_SHARED=OFF
        -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF -DWITH_SIMD=OFF
    BUILD_COMMAND "${CMAKE_COMMAND}" --build <BINARY_DIR> --target jpeg-static --parallel 4
    INSTALL_COMMAND "" BUILD_BYPRODUCTS "${thru_jpeg_BINARY_DIR}/libjpeg.a")
add_library(JPEG::JPEG STATIC IMPORTED GLOBAL)
set_target_properties(JPEG::JPEG PROPERTIES IMPORTED_LOCATION "${thru_jpeg_BINARY_DIR}/libjpeg.a"
    INTERFACE_INCLUDE_DIRECTORIES "${thru_jpeg_SOURCE_DIR}/src;${thru_jpeg_BINARY_DIR}")
add_dependencies(JPEG::JPEG thru_jpeg_build)
set(JPEG_FOUND TRUE)
set(JPEG_LIBRARIES JPEG::JPEG)
set(JPEG_INCLUDE_DIRS "${thru_jpeg_SOURCE_DIR};${thru_jpeg_BINARY_DIR}")
set(HAVE_JPEGTURBO_DUAL_MODE_8 TRUE CACHE INTERNAL "Pinned libjpeg-turbo 3.1.2 API")
set(HAVE_JPEGTURBO_DUAL_MODE_12 TRUE CACHE INTERNAL "Pinned libjpeg-turbo 3.1.2 API")
foreach(option tiff-tools tiff-tests tiff-contrib tiff-docs tiff-install cxx lzma zstd webp jbig lerc libdeflate)
    set(${option} OFF CACHE BOOL "" FORCE)
endforeach()
set(tiff-static ON CACHE BOOL "" FORCE)
set(jpeg ON CACHE BOOL "" FORCE)
FetchContent_Declare(thru_tiff URL "${CMAKE_CURRENT_LIST_DIR}/../../third_party/tiff/tiff-4.7.2.tar.xz"
    URL_HASH SHA256=4996f0c4f93094719b1ca5c6279b20e588773ba8a247533e486416fb662ddb88
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_MakeAvailable(thru_tiff)
add_dependencies(tiff thru_jpeg_build)
target_compile_options(tiff PRIVATE "$<$<CONFIG:Debug>:-O2>")
add_library(quest_tiff SHARED tiff_image.cpp tiff_jni.cpp)
target_compile_features(quest_tiff PRIVATE cxx_std_17)
target_compile_options(quest_tiff PRIVATE -Wall -Wextra -Werror -fexceptions "$<$<CONFIG:Debug>:-O2>")
target_link_libraries(quest_tiff PRIVATE tiff)
target_link_options(quest_tiff PRIVATE "-Wl,-z,max-page-size=16384" "-Wl,--exclude-libs,ALL")
add_executable(tiff_probe EXCLUDE_FROM_ALL ../../tests/native/tiff_probe.cpp tiff_image.cpp)
target_compile_features(tiff_probe PRIVATE cxx_std_17)
target_link_libraries(tiff_probe PRIVATE tiff)
