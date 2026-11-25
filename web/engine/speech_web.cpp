// WebAssembly bridge for on-device speech recognition (whisper.cpp), run in
// a Web Worker. Progress goes to JS through Module.onSpeechProgress.
#include <emscripten/emscripten.h>

#include <cstdlib>

#include "hbr/hbr_speech.h"

EM_JS(int, hbrw_speech_progress_js, (int pct), {
  if (Module.onSpeechProgress) return Module.onSpeechProgress(pct) ? 1 : 0;
  return 0;
});

extern "C" {
EMSCRIPTEN_KEEPALIVE void* hbrw_salloc(int bytes) { return std::malloc(bytes); }
EMSCRIPTEN_KEEPALIVE void hbrw_sfree(void* p) { std::free(p); }

EMSCRIPTEN_KEEPALIVE hbr_speech* hbrw_speech_load(void* data, int size) {
  return hbr_speech_load_buffer(data, static_cast<unsigned long>(size));
}

EMSCRIPTEN_KEEPALIVE char* hbrw_speech_transcribe(hbr_speech* s, float* pcm, int n, const char* lang) {
  return hbr_speech_transcribe(s, pcm, n, lang, 1,
                               [](int pct, void*) { return hbrw_speech_progress_js(pct); }, nullptr);
}

EMSCRIPTEN_KEEPALIVE void hbrw_speech_free(char* p) { hbr_speech_free(p); }
}
