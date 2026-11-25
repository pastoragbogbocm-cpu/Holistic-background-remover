#!/usr/bin/env bash
# Builds the web app into web/dist. Needs emsdk (emcc) and node.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p dist/vendor dist/models
em++ -O3 -msimd128 -std=c++17 -I../core/include \
  ../core/src/hbr_core.cpp engine/hbr_web.cpp \
  -s MODULARIZE=1 -s EXPORT_ES6=1 -s EXPORT_NAME=createHbr -s ENVIRONMENT=web \
  -s ALLOW_MEMORY_GROWTH=1 -s INITIAL_MEMORY=134217728 -s MAXIMUM_MEMORY=4294967296 \
  -s EXPORTED_RUNTIME_METHODS='["HEAPU8","HEAPF32"]' -s FILESYSTEM=0 \
  -o dist/hbr_core.js
[ -d node_modules ] || npm install --silent
npx esbuild src/app.js --bundle --format=esm --minify --target=es2022 \
  --external:./hbr_core.js --outfile=dist/app.js
cp node_modules/@mediapipe/tasks-vision/wasm/vision_wasm_internal.{js,wasm} dist/vendor/
cp ../packages/hbr_engine/android/src/main/assets/selfie_segmenter*.tflite dist/models/
cp src/index.html src/sw.js src/manifest.webmanifest dist/
echo "built web/dist"
