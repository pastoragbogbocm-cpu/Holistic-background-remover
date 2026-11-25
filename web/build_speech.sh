#!/usr/bin/env bash
# Builds the speech module (whisper.cpp + HBR wrapper) to WebAssembly.
# Needs emsdk in PATH and tools/speech/fetch.sh to have fetched the source.
set -euo pipefail
cd "$(dirname "$0")"
B=build-speech
emcmake cmake -S ../speech -B "$B" -DCMAKE_BUILD_TYPE=Release \
  -DGGML_NATIVE=OFF -DWHISPER_WASM_SINGLE_FILE=OFF \
  -DCMAKE_C_FLAGS="-msimd128 -O3" -DCMAKE_CXX_FLAGS="-msimd128 -O3" > /dev/null
cmake --build "$B" -j8 --target hbr_speech > /dev/null
libs=$(find "$B" -name '*.a' | tr '\n' ' ')
mkdir -p src
em++ -O3 -msimd128 -std=c++17 -I../speech/include engine/speech_web.cpp $libs \
  -s MODULARIZE=1 -s EXPORT_ES6=1 -s EXPORT_NAME=createSpeech -s ENVIRONMENT=worker \
  -s ALLOW_MEMORY_GROWTH=1 -s INITIAL_MEMORY=134217728 -s MAXIMUM_MEMORY=2147483648 \
  -s EXPORTED_RUNTIME_METHODS='["HEAPU8","HEAPF32","UTF8ToString","stringToUTF8","lengthBytesUTF8"]' \
  -s FILESYSTEM=0 -o src/hbr_speech.js
ls -la src/hbr_speech.*
