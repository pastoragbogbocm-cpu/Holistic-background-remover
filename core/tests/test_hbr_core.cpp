// Unit tests for the HBR core. Plain asserts, no framework, so they build
// anywhere (desktop CI, Android host tests, Xcode).
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "hbr/hbr_core.h"

static int failures = 0;
#define CHECK(cond, ...)                                  \
  do {                                                    \
    if (!(cond)) {                                        \
      std::printf("FAIL %s:%d: ", __FILE__, __LINE__);    \
      std::printf(__VA_ARGS__);                           \
      std::printf("\n");                                  \
      ++failures;                                         \
    }                                                     \
  } while (0)

struct Frame {
  int w, h;
  std::vector<uint8_t> y, uv;  // NV12
  Frame(int w_, int h_) : w(w_), h(h_), y(w_ * h_), uv(((w_ + 1) / 2) * 2 * ((h_ + 1) / 2)) {}
  hbr_yuv view() {
    return hbr_yuv{y.data(), w, uv.data(), uv.data() + 1, ((w + 1) / 2) * 2, 2};
  }
};

static void fill_noise(Frame& f, unsigned seed) {
  srand(seed);
  for (auto& v : f.y) v = 16 + rand() % 220;
  for (auto& v : f.uv) v = 16 + rand() % 224;
}

static hbr_engine* make(int w, int h, float temporal = 0.6f) {
  hbr_config c;
  hbr_default_config(&c, w, h);
  c.temporal_strength = temporal;
  return hbr_create(&c);
}

static void test_full_person_is_lossless() {
  Frame f(321, 179);  // odd sizes on purpose
  fill_noise(f, 1);
  Frame out = f;
  hbr_engine* e = make(f.w, f.h);
  std::vector<uint8_t> mask(64 * 64, 255);
  CHECK(hbr_refine_u8(e, f.y.data(), f.w, mask.data(), 64, 64, 64, 0) == 0, "refine");
  hbr_yuv s = f.view(), d = out.view();
  hbr_composite_color(e, &s, &d, 16, 128, 128);
  CHECK(out.y == f.y, "luma must be bit-exact where alpha is 255");
  CHECK(out.uv == f.uv, "chroma must be bit-exact where alpha is 255");
  hbr_destroy(e);
}

static void test_no_person_is_background() {
  Frame f(200, 120);
  fill_noise(f, 2);
  hbr_engine* e = make(f.w, f.h);
  std::vector<uint8_t> mask(32 * 32, 0);
  hbr_refine_u8(e, f.y.data(), f.w, mask.data(), 32, 32, 32, 0);
  hbr_yuv s = f.view();
  hbr_composite_color(e, &s, &s, 81, 90, 240);  // in place
  bool ok = true;
  for (auto v : f.y) ok &= v == 81;
  for (size_t i = 0; i < f.uv.size(); i += 2) ok &= f.uv[i] == 90 && f.uv[i + 1] == 240;
  CHECK(ok, "all pixels must be background colour");
  hbr_destroy(e);
}

// A crisp luma edge plus a blurry low-res mask: the guided filter must snap
// the matte to the real edge at full resolution.
static void test_edge_snapping() {
  const int W = 1280, H = 720, edge = 641;
  Frame f(W, H);
  for (int y = 0; y < H; ++y)
    for (int x = 0; x < W; ++x) f.y[y * W + x] = x < edge ? 200 : 40;
  std::fill(f.uv.begin(), f.uv.end(), 128);
  const int mw = 64, mh = 36;
  std::vector<float> mask(mw * mh);
  for (int y = 0; y < mh; ++y)
    for (int x = 0; x < mw; ++x) {
      // soft edge over ~2 mask pixels, like a real segmentation model
      float fx = (x + 0.5f) / mw;
      mask[y * mw + x] = std::fmin(1.f, std::fmax(0.f, (0.5f - fx) * mw / 2.f + 0.5f));
    }
  hbr_engine* e = make(W, H, 0.f);
  hbr_refine_f32(e, f.y.data(), W, mask.data(), mw, mh, mw, 0);
  int stride;
  const uint8_t* a = hbr_alpha(e, &stride);
  int row = H / 2;
  int first_partial = -1, last_partial = -1;
  for (int x = 0; x < W; ++x) {
    uint8_t v = a[row * stride + x];
    if (v > 10 && v < 245) {
      if (first_partial < 0) first_partial = x;
      last_partial = x;
    }
  }
  int width = first_partial < 0 ? 0 : last_partial - first_partial + 1;
  // naive bilinear upscale of the mask would give a ~40 px soft ramp
  CHECK(width < 24, "edge transition too wide: %d px", width);
  CHECK(a[row * stride + edge - 40] > 240, "inside should be opaque: %d", a[row * stride + edge - 40]);
  CHECK(a[row * stride + edge + 40] < 15, "outside should be clear: %d", a[row * stride + edge + 40]);
  hbr_destroy(e);
}

static double jitter_energy(float temporal) {
  const int W = 320, H = 240, mw = 32, mh = 32;
  Frame f(W, H);
  for (int y = 0; y < H; ++y)
    for (int x = 0; x < W; ++x) f.y[y * W + x] = 120;  // flat: guide can't help
  hbr_engine* e = make(W, H, temporal);
  std::vector<float> mask(mw * mh);
  std::vector<int> prev;
  double energy = 0;
  srand(7);
  for (int t = 0; t < 30; ++t) {
    for (auto& m : mask) m = 0.5f + ((rand() % 2001) / 1000.f - 1.f) * 0.06f;
    hbr_refine_f32(e, f.y.data(), W, mask.data(), mw, mh, mw, 0);
    int st;
    const uint8_t* a = hbr_alpha(e, &st);
    std::vector<int> cur(a, a + W * H);
    if (!prev.empty())
      for (int i = 0; i < W * H; ++i) energy += std::abs(cur[i] - prev[i]);
    prev.swap(cur);
  }
  hbr_destroy(e);
  return energy;
}

static void test_temporal_smoothing() {
  double off = jitter_energy(0.f), on = jitter_energy(0.6f);
  CHECK(on < off * 0.6, "smoothing should cut flicker: on=%.0f off=%.0f", on, off);

  // Real motion must not lag: jump from empty to full mask.
  const int W = 160, H = 120;
  Frame f(W, H);
  std::fill(f.y.begin(), f.y.end(), 100);
  hbr_engine* e = make(W, H, 1.f);
  std::vector<uint8_t> m0(16 * 16, 0), m1(16 * 16, 255);
  hbr_refine_u8(e, f.y.data(), W, m0.data(), 16, 16, 16, 0);
  hbr_refine_u8(e, f.y.data(), W, m1.data(), 16, 16, 16, 0);
  int st;
  CHECK(hbr_alpha(e, &st)[60 * W + 80] > 240, "large changes must pass through immediately");
  hbr_destroy(e);
}

static void test_rotation_mapping() {
  // Stored frame is landscape 64x32 but the video is shown rotated 90 deg
  // clockwise (portrait 32x64). Mask = person in the top half of the
  // portrait image. Top of the portrait image = left of the stored frame.
  const int W = 64, H = 32;
  Frame f(W, H);
  std::fill(f.y.begin(), f.y.end(), 128);
  std::vector<uint8_t> mask(32 * 64);
  for (int y = 0; y < 64; ++y)
    for (int x = 0; x < 32; ++x) mask[y * 32 + x] = y < 32 ? 255 : 0;
  hbr_engine* e = make(W, H, 0.f);
  hbr_refine_u8(e, f.y.data(), W, mask.data(), 32, 64, 32, 90);
  int st;
  const uint8_t* a = hbr_alpha(e, &st);
  CHECK(a[16 * st + 4] > 240 && a[16 * st + 60] < 15,
        "rot90: left=%d right=%d", a[16 * st + 4], a[16 * st + 60]);
  hbr_refine_u8(e, f.y.data(), W, mask.data(), 32, 64, 32, 270);
  a = hbr_alpha(e, &st);
  CHECK(a[16 * st + 4] < 15 && a[16 * st + 60] > 240,
        "rot270: left=%d right=%d", a[16 * st + 4], a[16 * st + 60]);
  hbr_destroy(e);
}

static void test_color_conversion() {
  uint8_t y, u, v;
  hbr_rgb_to_yuv(255, 255, 255, HBR_MATRIX_BT709, 0, &y, &u, &v);
  CHECK(y == 235 && u == 128 && v == 128, "white limited: %d %d %d", y, u, v);
  hbr_rgb_to_yuv(0, 0, 0, HBR_MATRIX_BT709, 0, &y, &u, &v);
  CHECK(y == 16 && u == 128 && v == 128, "black limited: %d %d %d", y, u, v);
  hbr_rgb_to_yuv(0, 255, 0, HBR_MATRIX_BT601, 1, &y, &u, &v);
  CHECK(y == 150 && u < 60 && v < 30, "green 601 full: %d %d %d", y, u, v);

  // RGBA -> YUV -> RGBA round trip
  const int w = 40, h = 30;
  std::vector<uint8_t> rgba(w * h * 4);
  for (int i = 0; i < w * h; ++i) {
    rgba[4 * i] = 200; rgba[4 * i + 1] = 60; rgba[4 * i + 2] = 30; rgba[4 * i + 3] = 255;
  }
  Frame f(80, 50);
  hbr_yuv d = f.view();
  CHECK(hbr_rgba_to_yuv_fill(rgba.data(), w, h, w * 4, &d, 80, 50, HBR_MATRIX_BT709, 0) == 0, "fill");
  std::vector<uint8_t> back(80 * 50 * 4);
  hbr_yuv_to_rgba(&d, 80, 50, back.data(), 80 * 4, HBR_MATRIX_BT709, 0);
  int i = (25 * 80 + 40) * 4;
  CHECK(std::abs(back[i] - 200) <= 2 && std::abs(back[i + 1] - 60) <= 2 && std::abs(back[i + 2] - 30) <= 2,
        "round trip: %d %d %d", back[i], back[i + 1], back[i + 2]);
}

static void test_scale_fill_and_planar() {
  Frame src(100, 60);
  std::fill(src.y.begin(), src.y.end(), 77);
  for (size_t i = 0; i < src.uv.size(); i += 2) { src.uv[i] = 99; src.uv[i + 1] = 150; }
  // I420 destination
  const int dw = 33, dh = 71, cw = 17, ch = 36;
  std::vector<uint8_t> Y(dw * dh), U(cw * ch), V(cw * ch);
  hbr_yuv d{Y.data(), dw, U.data(), V.data(), cw, 1};
  hbr_yuv s = src.view();
  CHECK(hbr_scale_yuv_fill(&s, 100, 60, &d, dw, dh) == 0, "scale");
  bool ok = true;
  for (auto v : Y) ok &= v == 77;
  for (auto v : U) ok &= v == 99;
  for (auto v : V) ok &= v == 150;
  CHECK(ok, "constant colour must survive scaling into planar layout");
}

static void test_blur_keeps_person() {
  const int W = 256, H = 144;
  Frame f(W, H);
  fill_noise(f, 3);
  // person = left half
  std::vector<uint8_t> mask(32 * 18);
  for (int y = 0; y < 18; ++y)
    for (int x = 0; x < 32; ++x) mask[y * 32 + x] = x < 12 ? 255 : 0;
  // make the guide agree with the mask (flat regions)
  hbr_engine* e = make(W, H, 0.f);
  hbr_refine_u8(e, f.y.data(), W, mask.data(), 32, 18, 32, 0);
  Frame out = f;
  hbr_yuv s = f.view(), d = out.view();
  CHECK(hbr_composite_blur(e, &s, &d, 0.05f) == 0, "blur");
  int st;
  const uint8_t* a = hbr_alpha(e, &st);
  long same = 0, opaque = 0;
  double var_in = 0, var_out = 0;
  for (int y = 0; y < H; ++y)
    for (int x = 0; x < W; ++x) {
      int i = y * W + x;
      if (a[i] == 255) { ++opaque; same += out.y[i] == f.y[i]; }
      if (x > W * 3 / 4) {
        var_in += std::abs(f.y[i] - 128);
        var_out += std::abs(out.y[i] - 128);
      }
    }
  CHECK(opaque > 0 && same == opaque, "person pixels must be untouched (%ld/%ld)", same, opaque);
  CHECK(var_out < var_in * 0.5, "background must be blurred: %.0f vs %.0f", var_out, var_in);
  hbr_destroy(e);
}

static void test_rotate() {
  // 4x2 frame, luma = index; rotate 90 cw -> 2x4
  Frame f(4, 2);
  for (int i = 0; i < 8; ++i) f.y[i] = static_cast<uint8_t>(i);
  f.uv = {10, 20, 30, 40};  // two chroma samples (U,V pairs)
  Frame r(2, 4);
  hbr_yuv s = f.view(), d = r.view();
  CHECK(hbr_rotate_yuv(&s, 4, 2, &d, 90) == 0, "rotate");
  // src rows: [0 1 2 3] / [4 5 6 7]; 90 cw: rows [4 0] [5 1] [6 2] [7 3]
  const uint8_t want[8] = {4, 0, 5, 1, 6, 2, 7, 3};
  CHECK(std::memcmp(r.y.data(), want, 8) == 0, "rot90 luma");
  // chroma 2x1 -> 1x2: (10,20) on top, (30,40) below
  CHECK(r.uv[0] == 10 && r.uv[1] == 20 && r.uv[2] == 30 && r.uv[3] == 40, "rot90 chroma");
  Frame back(4, 2);
  hbr_yuv b = back.view();
  hbr_rotate_yuv(&d, 2, 4, &b, 270);
  CHECK(back.y == f.y && back.uv == f.uv, "rot90 then rot270 is identity");
}

int main() {
  test_rotate();
  test_full_person_is_lossless();
  test_no_person_is_background();
  test_edge_snapping();
  test_temporal_smoothing();
  test_rotation_mapping();
  test_color_conversion();
  test_scale_fill_and_planar();
  test_blur_keeps_person();
  if (failures) {
    std::printf("%d check(s) failed\n", failures);
    return 1;
  }
  std::printf("all hbr_core tests passed\n");
  return 0;
}
