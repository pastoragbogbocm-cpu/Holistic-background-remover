#!/usr/bin/env bash
# Builds the web app into web/dist. Needs emsdk (emcc) and node.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p dist/vendor
em++ -O3 -msimd128 -std=c++17 -I../core/include \
  ../core/src/hbr_core.cpp engine/hbr_web.cpp \
  -s MODULARIZE=1 -s EXPORT_ES6=1 -s EXPORT_NAME=createHbr -s ENVIRONMENT=web \
  -s ALLOW_MEMORY_GROWTH=1 -s INITIAL_MEMORY=134217728 -s MAXIMUM_MEMORY=4294967296 \
  -s EXPORTED_RUNTIME_METHODS='["HEAPU8","HEAPF32"]' -s FILESYSTEM=0 \
  -o dist/hbr_core.js
[ -d node_modules ] || npm install --silent
node tools_embed_models.mjs ../packages/hbr_engine/android/src/main/assets dist/models.js
npx esbuild src/app.js --bundle --format=esm --minify --target=es2022 \
  --external:./hbr_core.js --external:./models.js --outfile=dist/app.js
# captions: speech worker + whisper.cpp WASM (build_speech.sh) + the small multilingual model
npx esbuild src/speech_worker.js --bundle --format=esm --minify --target=es2022 \
  --external:./hbr_speech.js --outfile=dist/speech_worker.js
cp src/hbr_speech.js src/hbr_speech.wasm dist/
mkdir -p dist/models
MODEL=${SPEECH_MODEL:-../third_party/models/ggml-tiny-q5_1.bin}
[ -f "$MODEL" ] || MODEL=/tmp/speech/ggml-tiny-q5_1.bin
rm -f dist/models/ggml-tiny-q5_1.bin*
cp "$MODEL" dist/models/ggml-tiny-q5_1.bin
cp node_modules/@mediapipe/tasks-vision/wasm/vision_wasm_internal.{js,wasm} dist/vendor/
cp src/index.html src/sw.js src/manifest.webmanifest dist/
echo "built web/dist"
