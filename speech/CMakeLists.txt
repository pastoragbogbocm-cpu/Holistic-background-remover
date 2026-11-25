cmake_minimum_required(VERSION 3.16)
project(hbr_speech CXX C)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# whisper.cpp is fetched by tools/speech/fetch.sh into third_party/.
set(HBR_WHISPER_DIR "${CMAKE_CURRENT_LIST_DIR}/../third_party/whisper.cpp" CACHE PATH "whisper.cpp source")
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
add_subdirectory(${HBR_WHISPER_DIR} whisper EXCLUDE_FROM_ALL)

add_library(hbr_speech STATIC src/hbr_speech.cpp)
target_include_directories(hbr_speech PUBLIC include)
target_link_libraries(hbr_speech PUBLIC whisper)

option(HBR_SPEECH_TESTS "Build the speech test tool" OFF)
if(HBR_SPEECH_TESTS)
  add_executable(hbr_speech_cli tests/speech_cli.cpp)
  target_link_libraries(hbr_speech_cli hbr_speech)
endif()
