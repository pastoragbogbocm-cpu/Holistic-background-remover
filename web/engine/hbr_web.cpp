// WebAssembly bridge for the shared HBR core (same engine as iOS/Android).
// All images are tight I420 buffers in the WASM heap unless noted.
#include <emscripten/emscripten.h>

#include <cstdlib>
#include <vector>

#include "hbr/hbr_core.h"

namespace {
hbr_yuv i420(uint8_t* base, int w, int h) {
  int cw = (w + 1) / 2, ch = (h + 1) / 2;
  uint8_t* u = base + static_cast<size_t>(w) * h;
  return hbr_yuv{base, w, u, u + static_cast<size_t>(cw) * ch, cw, 1};
}
}  // namespace

extern "C" {

EMSCRIPTEN_KEEPALIVE void* hbrw_alloc(int bytes) { return std::malloc(bytes); }
EMSCRIPTEN_KEEPALIVE void hbrw_free(void* p) { std::free(p); }

EMSCRIPTEN_KEEPALIVE hbr_engine* hbrw_create(int w, int h, float temporal, float low,
                                             float high, float smoothing, int clean) {
  hbr_config c;
  hbr_default_config(&c, w, h);
  c.temporal_strength = temporal;
  c.matte_low = low;
  c.matte_high = high;
  c.edge_smoothing = smoothing;
  c.decontaminate = clean;
  c.threads = 1;
  return hbr_create(&c);
}

EMSCRIPTEN_KEEPALIVE void hbrw_destroy(hbr_engine* e) { hbr_destroy(e); }

EMSCRIPTEN_KEEPALIVE int hbrw_refine(hbr_engine* e, uint8_t* frame, int w, float* mask,
                                     int mw, int mh, int rot) {
  return hbr_refine_f32(e, frame, w, mask, mw, mh, mw, rot);
}

// mode: 0 color (packed 0xYYUUVV), 1 image (bg I420 of frame size), 2 blur
EMSCRIPTEN_KEEPALIVE int hbrw_composite(hbr_engine* e, int mode, uint8_t* src, uint8_t* dst,
                                        int w, int h, uint8_t* bg, int color, float blur) {
  hbr_yuv s = i420(src, w, h), d = i420(dst, w, h);
  switch (mode) {
    case 0:
      return hbr_composite_color(e, &s, &d, (color >> 16) & 255, (color >> 8) & 255, color & 255);
    case 1: {
      hbr_yuv b = i420(bg, w, h);
      return hbr_composite_image(e, &s, &b, &d);
    }
    case 2:
      return hbr_composite_blur(e, &s, &d, blur);
  }
  return -1;
}

// NV12 (Y plane + interleaved UV) -> tight I420.
EMSCRIPTEN_KEEPALIVE void hbrw_nv12_to_i420(uint8_t* nv12, int w, int h, uint8_t* dst) {
  hbr_yuv d = i420(dst, w, h);
  const uint8_t* uv = nv12 + static_cast<size_t>(w) * h;
  for (size_t i = 0; i < static_cast<size_t>(w) * h; ++i) d.y[i] = nv12[i];
  int cw = (w + 1) / 2, ch = (h + 1) / 2;
  for (int y = 0; y < ch; ++y)
    for (int x = 0; x < cw; ++x) {
      d.u[y * cw + x] = uv[y * cw * 2 + 2 * x];
      d.v[y * cw + x] = uv[y * cw * 2 + 2 * x + 1];
    }
}

EMSCRIPTEN_KEEPALIVE int hbrw_i420_to_rgba_scaled(uint8_t* src, int w, int h, uint8_t* rgba,
                                                  int sw, int sh, int matrix, int full) {
  std::vector<uint8_t> small(static_cast<size_t>(sw) * sh +
                             2 * static_cast<size_t>((sw + 1) / 2) * ((sh + 1) / 2));
  hbr_yuv s = i420(src, w, h), m = i420(small.data(), sw, sh);
  hbr_scale_yuv_fill(&s, w, h, &m, sw, sh);
  return hbr_yuv_to_rgba(&m, sw, sh, rgba, sw * 4, static_cast<hbr_matrix>(matrix), full);
}

EMSCRIPTEN_KEEPALIVE int hbrw_i420_to_rgba(uint8_t* src, int w, int h, uint8_t* rgba, int matrix,
                                           int full) {
  hbr_yuv s = i420(src, w, h);
  return hbr_yuv_to_rgba(&s, w, h, rgba, w * 4, static_cast<hbr_matrix>(matrix), full);
}

EMSCRIPTEN_KEEPALIVE int hbrw_rgba_to_i420_fill(uint8_t* rgba, int w, int h, uint8_t* dst,
                                                int dw, int dh, int matrix, int full) {
  hbr_yuv d = i420(dst, dw, dh);
  return hbr_rgba_to_yuv_fill(rgba, w, h, w * 4, &d, dw, dh, static_cast<hbr_matrix>(matrix), full);
}

EMSCRIPTEN_KEEPALIVE int hbrw_rotate_i420(uint8_t* src, int w, int h, uint8_t* dst, int rot) {
  bool swap = rot == 90 || rot == 270;
  hbr_yuv s = i420(src, w, h), d = i420(dst, swap ? h : w, swap ? w : h);
  return hbr_rotate_yuv(&s, w, h, &d, rot);
}

EMSCRIPTEN_KEEPALIVE int hbrw_rgb_to_yuv(int r, int g, int b, int matrix, int full) {
  uint8_t y, u, v;
  hbr_rgb_to_yuv(r, g, b, static_cast<hbr_matrix>(matrix), full, &y, &u, &v);
  return (y << 16) | (u << 8) | v;
}
}
