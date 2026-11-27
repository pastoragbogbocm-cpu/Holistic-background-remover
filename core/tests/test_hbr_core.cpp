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

// Hair-like soft edge: pixels are a mix of the person (Y=200) and the
// old background (Y=40). After replacing the background with Y=120, the
// edge must not keep a dark fringe from the old background.
static double fringe_error(int decontaminate) {
  const int W = 640, H = 360, edge = 320, ramp = 24;
  Frame f(W, H);
  std::vector<float> truth(W);
  for (int x = 0; x < W; ++x) {
    float t = std::fmin(1.f, std::fmax(0.f, (edge + ramp / 2.f - x) / ramp));
    truth[x] = t;
    for (int y = 0; y < H; ++y) f.y[y * W + x] = static_cast<uint8_t>(40 + 160 * t + 0.5f);
  }
  std::fill(f.uv.begin(), f.uv.end(), 128);
  const int mw = 64, mh = 36;
  std::vector<float> mask(mw * mh);
  for (int y = 0; y < mh; ++y)
    for (int x = 0; x < mw; ++x) mask[y * mw + x] = (x + 0.5f) * W / mw < edge ? 1.f : 0.f;
  hbr_config c;
  hbr_default_config(&c, W, H);
  c.temporal_strength = 0;
  c.decontaminate = decontaminate;
  hbr_engine* e = hbr_create(&c);
  hbr_refine_f32(e, f.y.data(), W, mask.data(), mw, mh, mw, 0);
  Frame out = f;
  hbr_yuv s = f.view(), d = out.view();
  hbr_composite_color(e, &s, &d, 120, 128, 128);
  int st;
  const uint8_t* a = hbr_alpha(e, &st);
  double err = 0;
  int n = 0;
  for (int x = 0; x < W; ++x) {
    int av = a[180 * st + x];
    if (av <= 5 || av >= 250) continue;
    double ideal = av / 255.0 * 200 + (1 - av / 255.0) * 120;
    err += std::fabs(out.y[180 * W + x] - ideal);
    ++n;
  }
  hbr_destroy(e);
  return n ? err / n : 0;
}

static void test_decontamination() {
  double off = fringe_error(0), on = fringe_error(1);
  CHECK(off > 3, "test setup should show a fringe without decontamination: %.2f", off);
  CHECK(on < off * 0.5, "decontamination should remove the fringe: on=%.2f off=%.2f", on, off);
}

// Width (in pixels) of the semi-transparent band on the middle row after a
// few frames in which a soft edge either stays put or moves sideways.
static int edge_band(bool moving, float sharpen) {
  const int W = 320, H = 96;
  hbr_config c;
  hbr_default_config(&c, W, H);
  c.motion_sharpen = sharpen;
  c.threads = 1;
  hbr_engine* e = hbr_create(&c);
  Frame f(W, H);
  std::vector<float> mask(W * H);
  for (int t = 0; t < 6; ++t) {
    int edge = 120 + (moving ? 14 * t : 70);
    for (int y = 0; y < H; ++y)
      for (int x = 0; x < W; ++x) {
        // soft (motion-blurred) luma ramp and a soft model mask around it
        float r = std::fmin(1.f, std::fmax(0.f, (x - (edge - 15)) / 30.f));
        f.y[y * W + x] = static_cast<uint8_t>(200 - 150 * r);
        mask[y * W + x] = std::fmin(1.f, std::fmax(0.f, ((edge + 20) - x) / 40.f));
      }
    std::fill(f.uv.begin(), f.uv.end(), 128);
    hbr_refine_f32(e, f.y.data(), W, mask.data(), W, H, W, 0);
  }
  int stride = 0;
  const uint8_t* a = hbr_alpha(e, &stride);
  int band = 0;
  for (int x = 0; x < W; ++x) {
    uint8_t v = a[(H / 2) * stride + x];
    if (v > 20 && v < 235) ++band;
  }
  hbr_destroy(e);
  return band;
}

static void test_motion_sharpen() {
  int still = edge_band(false, 0.85f);
  int moving_off = edge_band(true, 0.f);
  int moving_on = edge_band(true, 0.85f);
  std::printf("edge band: still %d px, moving %d px -> %d px with motion sharpen\n",
              still, moving_off, moving_on);
  CHECK(moving_on < moving_off * 0.75, "moving edge band not narrower (%d vs %d)", moving_on, moving_off);
  CHECK(moving_on > 0, "moving edge became a hard cut");
  CHECK(still == edge_band(false, 0.f), "still edges must not change (%d)", still);
}

static void test_layout() {
  int x, y, w, h;
  // 16:9 video on a square canvas
  hbr_place_rect(1920, 1080, 1080, 1080, 0, 1.f, 0.f, 0.f, &x, &y, &w, &h);
  CHECK(w == 1920 && h == 1080 && x == -420 && y == 0, "cover %d %d %d %d", x, y, w, h);
  hbr_place_rect(1920, 1080, 1080, 1080, 1, 1.f, 0.f, 0.f, &x, &y, &w, &h);
  CHECK(w == 1080 && h == 608 && x == 0 && y == 236, "fit %d %d %d %d", x, y, w, h);
  hbr_place_rect(1920, 1080, 1080, 1080, 0, 1.f, -1.f, 0.f, &x, &y, &w, &h);
  CHECK(x == 0, "pan left %d", x);
  hbr_place_rect(1920, 1080, 1080, 1080, 0, 1.f, 1.f, 0.f, &x, &y, &w, &h);
  CHECK(x == 1080 - 1920, "pan right %d", x);
  hbr_place_rect(100, 100, 200, 200, 0, 0.5f, 1.f, 1.f, &x, &y, &w, &h);
  CHECK(w == 100 && x == 100 && y == 100, "smaller, bottom-right %d %d %d", x, y, w);
  hbr_place_rect(1080, 1920, 1080, 1920, 0, 1.f, 0.f, 0.f, &x, &y, &w, &h);
  CHECK(x == 0 && y == 0 && w == 1080 && h == 1920, "identity %d %d %d %d", x, y, w, h);

  // exact copy for a same-size blit, colour fill around a smaller one
  Frame a(64, 48), b(64, 48);
  fill_noise(a, 5);
  hbr_yuv av = a.view(), bv = b.view();
  hbr_blit_yuv(&av, 64, 48, &bv, 64, 48, 0, 0, 64, 48);
  CHECK(a.y == b.y && a.uv == b.uv, "same-size blit not exact");
  hbr_fill_yuv(&bv, 64, 48, 10, 20, 30);
  hbr_blit_yuv(&av, 64, 48, &bv, 64, 48, 16, 12, 32, 24);
  CHECK(b.y[0] == 10 && b.y[47 * 64 + 63] == 10, "outside rect must keep fill");
  CHECK(b.y[24 * 64 + 32] != 10 || a.y[24 * 64 + 32] == 10, "inside rect must be drawn");
  // crop is the inverse of blit
  Frame c(64, 48);
  hbr_yuv cv = c.view();
  hbr_crop_yuv(&av, 64, 48, 0, 0, 64, 48, &cv, 64, 48);
  CHECK(a.y == c.y, "identity crop not exact");
  // blur keeps flat images flat
  hbr_fill_yuv(&bv, 64, 48, 100, 120, 140);
  hbr_blur_yuv(&bv, 64, 48, 0.05f);
  CHECK(b.y[10 * 64 + 10] == 100 && b.uv[10] == 120, "blur changed a flat image");
}

static void test_overlay() {
  Frame f(32, 32);
  std::fill(f.y.begin(), f.y.end(), 16);
  std::fill(f.uv.begin(), f.uv.end(), 128);
  hbr_yuv v = f.view();
  // 8x8 opaque white square at (4,4), half-transparent red at (20,20)
  std::vector<uint8_t> img(8 * 8 * 4, 255);
  hbr_overlay_rgba(&v, 32, 32, img.data(), 8, 8, 32, 4, 4, 0, HBR_MATRIX_BT709, 0);
  CHECK(f.y[6 * 32 + 6] == 235, "white overlay luma %d", f.y[6 * 32 + 6]);
  CHECK(f.y[2 * 32 + 2] == 16, "outside overlay changed");
  for (size_t i = 0; i < img.size(); i += 4) { img[i] = 128; img[i + 1] = 0; img[i + 2] = 0; img[i + 3] = 128; }
  hbr_overlay_rgba(&v, 32, 32, img.data(), 8, 8, 32, 20, 20, 1, HBR_MATRIX_BT709, 0);  // premultiplied red @50%
  int vv = f.uv[(22 / 2) * 32 + (22 / 2) * 2 + 1];
  CHECK(vv > 160, "red overlay should raise Cr, got %d", vv);
  // clipping: partly outside must not crash or write outside
  hbr_overlay_rgba(&v, 32, 32, img.data(), 8, 8, 32, 28, -4, 1, HBR_MATRIX_BT709, 0);
}

static void test_outline() {
  const int W = 160, H = 160;
  Frame f(W, H);
  std::fill(f.y.begin(), f.y.end(), 120);
  std::fill(f.uv.begin(), f.uv.end(), 128);
  hbr_engine* e = make(W, H, 0.f);
  // person = disc of radius 40 in the middle
  std::vector<uint8_t> mask(64 * 64);
  for (int y = 0; y < 64; ++y)
    for (int x = 0; x < 64; ++x) mask[y * 64 + x] = ((x - 32) * (x - 32) + (y - 32) * (y - 32) < 16 * 16) ? 255 : 0;
  CHECK(hbr_refine_u8(e, f.y.data(), W, mask.data(), 64, 64, 64, 0) == 0, "refine");
  Frame out = f;
  hbr_yuv s = f.view(), d = out.view();
  hbr_composite_color(e, &s, &d, 16, 128, 128);
  CHECK(hbr_draw_outline(e, &d, W, H, 235, 128, 128, 0.05f, 0) == 0, "outline");  // 8 px white
  int st;
  const uint8_t* a = hbr_alpha(e, &st);
  // find the person's right edge on the middle row, then look just outside it
  int edge = W / 2;
  while (edge < W - 1 && a[(H / 2) * st + edge] >= 128) ++edge;
  CHECK(out.y[(H / 2) * W + edge + 3] > 200, "outline missing next to the person: %d", out.y[(H / 2) * W + edge + 3]);
  CHECK(out.y[(H / 2) * W + edge + 20] == 16, "outline too wide: %d", out.y[(H / 2) * W + edge + 20]);
  CHECK(out.y[(H / 2) * W + W / 2] == 120, "person must stay untouched: %d", out.y[(H / 2) * W + W / 2]);
  CHECK(out.y[5 * W + 5] == 16, "far background changed");
  // glow: softer and wider, fading out
  Frame g = f;
  hbr_yuv gd = g.view();
  hbr_composite_color(e, &s, &gd, 16, 128, 128);
  hbr_draw_outline(e, &gd, W, H, 235, 128, 128, 0.05f, 1);
  int near = g.y[(H / 2) * W + edge + 2], mid = g.y[(H / 2) * W + edge + 10];
  CHECK(near > mid && mid > 16, "glow should fade out: near %d mid %d", near, mid);
  CHECK(hbr_draw_outline(e, &gd, W + 2, H, 235, 128, 128, 0.05f, 0) != 0, "size mismatch must be rejected");
  hbr_destroy(e);
}

static void test_transitions() {
  const int W = 96, H = 64;
  Frame A(W, H), B(W, H), O(W, H);
  std::fill(A.y.begin(), A.y.end(), 50);
  std::fill(B.y.begin(), B.y.end(), 200);
  std::fill(A.uv.begin(), A.uv.end(), 128);
  std::fill(B.uv.begin(), B.uv.end(), 128);
  hbr_yuv a = A.view(), b = B.view(), o = O.view();
  for (int rot : {0, 90}) {
    for (int type = 0; type < HBR_TR_COUNT; ++type) {
      hbr_transition(&a, &b, &o, W, H, rot, type, 0.f);
      int c0 = O.y[(H / 2) * W + W / 2];
      hbr_transition(&a, &b, &o, W, H, rot, type, 1.f);
      int c1 = O.y[(H / 2) * W + W / 2], k1 = O.y[2 * W + 2];
      CHECK(std::abs(c0 - 50) <= 2, "type %d rot %d must start on a: %d", type, rot, c0);
      CHECK(std::abs(c1 - 200) <= 2 && std::abs(k1 - 200) <= 2, "type %d rot %d must end on b: %d %d", type, rot, c1, k1);
      hbr_transition(&a, &b, &o, W, H, rot, type, 0.5f);  // must not crash; mid-way differs from both for most
    }
  }
  // slide from the right as the viewer sees it: halfway, the right half shows b
  hbr_transition(&a, &b, &o, W, H, 0, HBR_TR_SLIDE, 0.5f);
  CHECK(O.y[(H / 2) * W + W - 4] > 190 && O.y[(H / 2) * W + 4] < 60, "slide direction");
  // rotated 90 clockwise for display: the stored top edge is the viewer's right
  hbr_transition(&a, &b, &o, W, H, 90, HBR_TR_SLIDE, 0.5f);
  CHECK(O.y[2 * W + W / 2] > 190 && O.y[(H - 3) * W + W / 2] < 60, "slide direction rotated: %d %d",
        O.y[2 * W + W / 2], O.y[(H - 3) * W + W / 2]);
  // zoom keeps the centre
  Frame Z(W, H);
  for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) A.y[y * W + x] = static_cast<uint8_t>(x * 2);
  hbr_yuv z = Z.view();
  CHECK(hbr_zoom_yuv(&a, &z, W, H, 2.f) == 0, "zoom");
  CHECK(std::abs(Z.y[(H / 2) * W + W / 2] - A.y[(H / 2) * W + W / 2]) <= 3, "zoom keeps centre");
  CHECK(Z.y[(H / 2) * W + 2] > A.y[(H / 2) * W + 2] + 30, "zoom magnifies");
}

int main() {
  test_outline();
  test_transitions();
  test_decontamination();
  test_motion_sharpen();
  test_layout();
  test_overlay();
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
