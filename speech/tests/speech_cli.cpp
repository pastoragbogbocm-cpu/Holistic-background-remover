// hbr_speech_cli model.bin audio.f32 [lang]  (16 kHz mono float32 raw)
#include <cstdio>
#include <vector>
#include "hbr/hbr_speech.h"
int main(int argc, char** argv) {
  if (argc < 3) return 2;
  FILE* f = std::fopen(argv[2], "rb");
  if (!f) return 3;
  std::vector<float> pcm;
  float buf[4096];
  size_t n;
  while ((n = std::fread(buf, sizeof(float), 4096, f)) > 0) pcm.insert(pcm.end(), buf, buf + n);
  std::fclose(f);
  hbr_speech* s = hbr_speech_load_file(argv[1]);
  if (!s) return 4;
  char* json = hbr_speech_transcribe(s, pcm.data(), (int)pcm.size(), argc > 3 ? argv[3] : "en", 0,
                                     [](int p, void*) { std::fprintf(stderr, "\r%d%%", p); return 0; }, nullptr);
  if (!json) return 5;
  std::printf("%s\n", json);
  hbr_speech_free(json);
  hbr_speech_destroy(s);
  return 0;
}
