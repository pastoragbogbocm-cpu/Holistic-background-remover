#include "hbr/hbr_speech.h"

#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "whisper.h"

struct hbr_speech {
  whisper_context* ctx = nullptr;
};

namespace {
whisper_context_params ctx_params(const char* hint) {
  whisper_context_params p = whisper_context_default_params();
  p.use_gpu = false;
  (void)hint;
  return p;
}

void json_escape(std::string& out, const std::string& s) {
  for (unsigned char c : s) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': case '\r': case '\t': out += ' '; break;
      default:
        if (c < 0x20) out += ' ';
        else out += static_cast<char>(c);
    }
  }
}

struct Word {
  std::string text;
  long t0, t1;
};

struct ProgressCtx {
  hbr_speech_progress fn;
  void* user;
  bool cancelled = false;
};
}  // namespace

extern "C" {

hbr_speech* hbr_speech_load_file(const char* path) {
  whisper_context* c = whisper_init_from_file_with_params(path, ctx_params(path));
  if (!c) return nullptr;
  auto* s = new hbr_speech();
  s->ctx = c;
  return s;
}

hbr_speech* hbr_speech_load_buffer(const void* data, unsigned long size) {
  whisper_context* c = whisper_init_from_buffer_with_params(const_cast<void*>(data), size, ctx_params(nullptr));
  if (!c) return nullptr;
  auto* s = new hbr_speech();
  s->ctx = c;
  return s;
}

void hbr_speech_destroy(hbr_speech* s) {
  if (!s) return;
  whisper_free(s->ctx);
  delete s;
}

char* hbr_speech_transcribe(hbr_speech* s, const float* pcm, int samples,
                            const char* language, int threads,
                            hbr_speech_progress progress, void* user) {
  if (!s || !pcm || samples <= 0) return nullptr;
  whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH);
  p.beam_search.beam_size = 3;
  p.print_progress = false;
  p.print_realtime = false;
  p.print_timestamps = false;
  p.print_special = false;
  p.translate = false;
  p.token_timestamps = true;
  p.thold_pt = 0.01f;
  p.suppress_blank = true;
  p.no_context = true;
  int hc = static_cast<int>(std::thread::hardware_concurrency());
  p.n_threads = threads > 0 ? threads : std::max(1, std::min(hc, 4));
  const bool autodetect = !language || !*language || std::strcmp(language, "auto") == 0;
  p.language = autodetect ? "auto" : language;
  p.detect_language = false;

  ProgressCtx pc{progress, user};
  if (progress) {
    p.progress_callback = [](whisper_context*, whisper_state*, int pct, void* u) {
      auto* c = static_cast<ProgressCtx*>(u);
      if (c->fn(pct, c->user)) c->cancelled = true;
    };
    p.progress_callback_user_data = &pc;
    p.abort_callback = [](void* u) { return static_cast<ProgressCtx*>(u)->cancelled; };
    p.abort_callback_user_data = &pc;
  }

  if (whisper_full(s->ctx, p, pcm, samples) != 0 || pc.cancelled) return nullptr;

  // Words from tokens: a token that starts with a space begins a new word.
  std::vector<Word> words;
  const whisper_token eot = whisper_token_eot(s->ctx);
  const int ns = whisper_full_n_segments(s->ctx);
  for (int i = 0; i < ns; ++i) {
    const int nt = whisper_full_n_tokens(s->ctx, i);
    for (int j = 0; j < nt; ++j) {
      whisper_token_data d = whisper_full_get_token_data(s->ctx, i, j);
      if (d.id >= eot) continue;  // special / timestamp tokens
      const char* txt = whisper_full_get_token_text(s->ctx, i, j);
      if (!txt || !*txt) continue;
      std::string t = txt;
      long t0 = d.t0 * 10, t1 = d.t1 * 10;
      bool starts = t[0] == ' ' || words.empty();
      if (starts) {
        size_t k = t.find_first_not_of(' ');
        if (k == std::string::npos) continue;
        words.push_back({t.substr(k), t0, t1});
      } else {
        words.back().text += t;
        words.back().t1 = std::max(words.back().t1, t1);
      }
    }
  }
  // tidy: monotonic, non-zero length
  for (size_t k = 0; k < words.size(); ++k) {
    if (k > 0 && words[k].t0 < words[k - 1].t1) words[k].t0 = words[k - 1].t1;
    if (words[k].t1 <= words[k].t0) words[k].t1 = words[k].t0 + 80;
  }

  std::string out = "[";
  for (size_t k = 0; k < words.size(); ++k) {
    if (k) out += ',';
    out += "{\"w\":\"";
    json_escape(out, words[k].text);
    out += "\",\"t0\":" + std::to_string(words[k].t0) + ",\"t1\":" + std::to_string(words[k].t1) + "}";
  }
  out += "]";
  char* r = static_cast<char*>(std::malloc(out.size() + 1));
  std::memcpy(r, out.c_str(), out.size() + 1);
  return r;
}

void hbr_speech_free(char* p) { std::free(p); }
}
