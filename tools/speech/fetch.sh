#!/usr/bin/env bash
# Fetches the pinned whisper.cpp source (on-device speech recognition for
# captions) and the speech models. Run before building the app.
#   tools/speech/fetch.sh            -> source + Android model
#   tools/speech/fetch.sh --all      -> also every model variant (for tests)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
WHISPER_TAG="v1.7.6"
src="$root/third_party/whisper.cpp"
if [ ! -f "$src/include/whisper.h" ]; then
  mkdir -p "$root/third_party"
  curl -fsSL "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/${WHISPER_TAG}.tar.gz" -o /tmp/whisper.tgz
  rm -rf "$src" && mkdir -p "$src"
  tar -xzf /tmp/whisper.tgz -C "$src" --strip-components=1
fi
hf=https://huggingface.co/ggerganov/whisper.cpp/resolve/main
assets="$root/packages/hbr_engine/android/src/main/assets"
get() { [ -s "$2" ] || curl -fsSL "$hf/$1" -o "$2"; }
get ggml-base-q5_1.bin "$assets/ggml-base-q5_1.bin"
if [ "${1:-}" = "--all" ]; then
  mkdir -p "$root/third_party/models"
  for m in ggml-tiny-q5_1.bin ggml-tiny.en-q5_1.bin ggml-base.en-q5_1.bin; do
    get "$m" "$root/third_party/models/$m"
  done
fi
ls -la "$assets" | grep ggml
