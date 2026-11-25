cmake_minimum_required(VERSION 3.22.1)
project(hbr_jni CXX)

# The portable engine lives at the repository root so iOS, Android and the
# future desktop/web builds share one implementation.
set(HBR_CORE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../core)
add_subdirectory(${HBR_CORE_DIR} ${CMAKE_CURRENT_BINARY_DIR}/hbr_core)

add_library(hbr_jni SHARED hbr_jni.cpp)
target_compile_options(hbr_jni PRIVATE -O3 -ffast-math)
target_compile_options(hbr_core PRIVATE -O3 -ffast-math)
target_link_libraries(hbr_jni hbr_core log)
# 16 KB page size alignment (required for new Play Store uploads).
target_link_options(hbr_jni PRIVATE "-Wl,-z,max-page-size=16384")
