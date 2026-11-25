cmake_minimum_required(VERSION 3.22.1)
project(hbr_jni CXX)

# The portable engine lives at the repository root so iOS, Android and the
# future desktop/web builds share one implementation.
set(HBR_CORE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../core)
add_subdirectory(${HBR_CORE_DIR} ${CMAKE_CURRENT_BINARY_DIR}/hbr_core)

# On-device speech recognition for captions (whisper.cpp, fetched by
# tools/speech/fetch.sh into third_party/).
set(HBR_SPEECH_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../speech)
if(NOT EXISTS ${HBR_SPEECH_DIR}/../third_party/whisper.cpp/include/whisper.h)
  message(FATAL_ERROR "whisper.cpp is missing: run tools/speech/fetch.sh first")
endif()
set(CMAKE_BUILD_TYPE Release)
add_subdirectory(${HBR_SPEECH_DIR} ${CMAKE_CURRENT_BINARY_DIR}/hbr_speech)

add_library(hbr_jni SHARED hbr_jni.cpp speech_jni.cpp)
target_compile_options(hbr_jni PRIVATE -O3 -ffast-math)
target_compile_options(hbr_core PRIVATE -O3 -ffast-math)
target_link_libraries(hbr_jni hbr_core hbr_speech log)
# 16 KB page size alignment (required for new Play Store uploads).
target_link_options(hbr_jni PRIVATE "-Wl,-z,max-page-size=16384")
