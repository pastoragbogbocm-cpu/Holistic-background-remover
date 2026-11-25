// HBR core implementation. See include/hbr/hbr_core.h for the contract.
//
// Everything here is plain C++17 with no dependencies so it builds with the
// Android NDK, Xcode, desktop compilers and Emscripten unchanged. Inner loops
// are written to auto-vectorise (NEON on phones, SSE/AVX on desktop).

#include "hbr/hbr_core.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <functional>
#include <thread>
#include <vector>

namespace {

// ------------------------------------------------------------------ utils

inline float clampf(float v, float lo, float hi) {
  return v < lo ? lo : (v > hi ? hi : v);
}
inline uint8_t to_u8(float v) {
  return static_cast<uint8_t>(clampf(v, 0.f, 255.f) + 0.5f);
}
inline float smoothstep(float e0, float e1, float x) {
  float t = clampf((x - e0) / (e1 - e0), 0.f, 1.f);
  return t * t * (3.f - 2.f * t);
}

void parallel_for(int n, int threads,
                  const std::function<void(int, int)>& fn) {
  if (n <= 0) return;
  int t = std::max(1, std::min(threads, n / 16));
  if (t <= 1) {
    fn(0, n);
    return;
  }
  std::vector<std::thread> pool;
  pool.reserve(t - 1);
  int chunk = (n + t - 1) / t;
  for (int i = 1; i < t; ++i) {
    int b = i * chunk, e = std::min(n, b + chunk);
    if (b < e) pool.emplace_back(fn, b, e);
  }
  fn(0, std::min(n, chunk));
  for (auto& th : pool) th.join();
}

// Resampling taps for one axis. Downscaling uses exact area averaging (no
// aliasing); upscaling uses bilinear with pixel-centre alignment.
struct Taps {
  std::vector<int> start;   // first source index per output sample
  std::vector<int> count;   // number of taps per output sample
  std::vector<int> offset;  // offset into weight array
  std::vector<float> w;
};

Taps make_taps(double src_start, double src_len, int src_n, int dst_n) {
  Taps t;
  t.start.resize(dst_n);
  t.count.resize(dst_n);
  t.offset.resize(dst_n);
  const double f = src_len / dst_n;
  for (int i = 0; i < dst_n; ++i) {
    t.offset[i] = static_cast<int>(t.w.size());
    if (f > 1.0) {
      double a = src_start + i * f, b = a + f;
      int ia = static_cast<int>(std::floor(a));
      int ib = static_cast<int>(std::ceil(b));
      ia = std::max(0, ia);
      ib = std::min(src_n, ib);
      t.start[i] = ia;
      float sum = 0.f;
      for (int s = ia; s < ib; ++s) {
        double ov = std::min<double>(b, s + 1) - std::max<double>(a, s);
        float wv = static_cast<float>(std::max(0.0, ov));
        t.w.push_back(wv);
        sum += wv;
      }
      t.count[i] = ib - ia;
      if (t.count[i] <= 0) {  // degenerate, fall back to nearest
        t.start[i] = std::min(src_n - 1, std::max(0, ia));
        t.count[i] = 1;
        t.w.push_back(1.f);
        sum = 1.f;
      }
      for (int k = 0; k < t.count[i]; ++k) t.w[t.offset[i] + k] /= sum;
    } else {
      double s = src_start + (i + 0.5) * f - 0.5;
      s = std::min<double>(std::max<double>(s, 0.0), src_n - 1);
      int s0 = static_cast<int>(std::floor(s));
      int s1 = std::min(src_n - 1, s0 + 1);
      float fr = static_cast<float>(s - s0);
      t.start[i] = s0;
      if (s1 == s0 || fr <= 0.f) {
        t.count[i] = 1;
        t.w.push_back(1.f);
      } else {
        t.count[i] = 2;
        t.w.push_back(1.f - fr);
        t.w.push_back(fr);
      }
    }
  }
  return t;
}

// Separable resample of one channel. `pix` is the distance between
// horizontally adjacent samples in the source (1 planar, 2 for NV12 chroma,
// 4 for an RGBA channel).
template <typename In>
void resample_to_float(const In* src, int sstride, int pix, const Taps& tx,
                       const Taps& ty, float scale, float* dst, int dw, int dh,
                       int threads) {
  // Horizontal pass on only the source rows that the vertical taps touch.
  int row_lo = ty.start.front();
  int row_hi = 0;
  for (size_t i = 0; i < ty.start.size(); ++i)
    row_hi = std::max(row_hi, ty.start[i] + ty.count[i]);
  int rows = row_hi - row_lo;
  std::vector<float> tmp(static_cast<size_t>(rows) * dw);
  parallel_for(rows, threads, [&](int b, int e) {
    for (int r = b; r < e; ++r) {
      const In* s = src + static_cast<size_t>(row_lo + r) * sstride;
      float* o = tmp.data() + static_cast<size_t>(r) * dw;
      for (int x = 0; x < dw; ++x) {
        const float* w = tx.w.data() + tx.offset[x];
        const In* p = s + static_cast<size_t>(tx.start[x]) * pix;
        float acc = 0.f;
        for (int k = 0; k < tx.count[x]; ++k) acc += w[k] * p[k * pix];
        o[x] = acc * scale;
      }
    }
  });
  parallel_for(dh, threads, [&](int b, int e) {
    for (int y = b; y < e; ++y) {
      float* o = dst + static_cast<size_t>(y) * dw;
      std::fill(o, o + dw, 0.f);
      const float* w = ty.w.data() + ty.offset[y];
      for (int k = 0; k < ty.count[y]; ++k) {
        const float* row =
            tmp.data() + static_cast<size_t>(ty.start[y] + k - row_lo) * dw;
        float wk = w[k];
        for (int x = 0; x < dw; ++x) o[x] += wk * row[x];
      }
    }
  });
}

// Mean filter with a (2r+1)^2 window, edge-normalised. O(1) per pixel.
void box_mean(const float* in, float* out, int w, int h, int r,
              std::vector<float>& tmp) {
  tmp.resize(static_cast<size_t>(w) * h);
  if (r <= 0) {
    std::memcpy(out, in, sizeof(float) * w * h);
    return;
  }
  // horizontal
  for (int y = 0; y < h; ++y) {
    const float* s = in + static_cast<size_t>(y) * w;
    float* o = tmp.data() + static_cast<size_t>(y) * w;
    double acc = 0;
    int lo = 0, hi = -1;  // window [lo, hi]
    for (int x = 0; x < w; ++x) {
      int nlo = std::max(0, x - r), nhi = std::min(w - 1, x + r);
      while (hi < nhi) acc += s[++hi];
      while (lo < nlo) acc -= s[lo++];
      o[x] = static_cast<float>(acc / (hi - lo + 1));
    }
  }
  // vertical, column sums kept in a row buffer for cache friendliness
  std::vector<double> col(w, 0.0);
  int lo = 0, hi = -1;
  for (int y = 0; y < h; ++y) {
    int nlo = std::max(0, y - r), nhi = std::min(h - 1, y + r);
    while (hi < nhi) {
      ++hi;
      const float* s = tmp.data() + static_cast<size_t>(hi) * w;
      for (int x = 0; x < w; ++x) col[x] += s[x];
    }
    while (lo < nlo) {
      const float* s = tmp.data() + static_cast<size_t>(lo) * w;
      for (int x = 0; x < w; ++x) col[x] -= s[x];
      ++lo;
    }
    float inv = 1.f / static_cast<float>(hi - lo + 1);
    float* o = out + static_cast<size_t>(y) * w;
    for (int x = 0; x < w; ++x) o[x] = static_cast<float>(col[x]) * inv;
  }
}

struct Coeffs {
  float kr, kb;
};
Coeffs coeffs(hbr_matrix m) {
  switch (m) {
    case HBR_MATRIX_BT601:
      return {0.299f, 0.114f};
    case HBR_MATRIX_BT2020:
      return {0.2627f, 0.0593f};
    case HBR_MATRIX_BT709:
    default:
      return {0.2126f, 0.0722f};
  }
}

inline void rgbf_to_yuv(float r, float g, float b, hbr_matrix m, int full,
                        float* yo, float* uo, float* vo) {
  Coeffs c = coeffs(m);
  float y = c.kr * r + (1.f - c.kr - c.kb) * g + c.kb * b;  // 0..1
  float cb = (b - y) / (2.f * (1.f - c.kb));                // -0.5..0.5
  float cr = (r - y) / (2.f * (1.f - c.kr));
  if (full) {
    *yo = y * 255.f;
    *uo = 128.f + cb * 255.f;
    *vo = 128.f + cr * 255.f;
  } else {
    *yo = 16.f + y * 219.f;
    *uo = 128.f + cb * 224.f;
    *vo = 128.f + cr * 224.f;
  }
}

}  // namespace

// ------------------------------------------------------------------ engine

struct hbr_engine {
  hbr_config cfg;
  int W = 0, H = 0;   // full res
  int gw = 0, gh = 0; // working (guide) res
  int threads = 1;
  Taps down_x, down_y;  // full -> working (area)
  Taps up_x, up_y;      // working -> full (bilinear)

  std::vector<float> guide, prev_guide, mask, prev_mask;
  std::vector<float> mI, mP, mIP, mII, a, b, tmp, scratch;
  bool has_prev = false;
  bool has_prev_coeffs = false;
  float mask_px = 1.f;  // working-res pixels per mask pixel
  std::vector<float> motion;          // per-pixel temporal update weight
  std::vector<float> moving;          // 0..1 how much this area moves now
  std::vector<float> prev_a, prev_b;  // previous guided-filter coefficients

  std::vector<uint8_t> alpha;       // W*H
  std::vector<uint8_t> prev_alpha;  // W*H, for full-res temporal smoothing
  std::vector<uint8_t> luma_dn;     // W*H, lightly denoised guide
  bool has_prev_alpha = false;

  // edge colour decontamination: local pure-foreground / pure-background
  // colour estimates at a reduced resolution
  int ew = 0, eh = 0;
  std::vector<float> fgp[3], bgp[3];
  Taps ex_l, ey_l, ex_c, ey_c;  // est -> full luma / chroma sampling
  std::vector<uint8_t> mixfrac;    // per-pixel estimated mixing fraction
  std::vector<uint8_t> alpha_eff;  // alpha after colour-based correction

  // blur background scratch
  std::vector<uint8_t> blur_y, blur_u, blur_v;
};

extern "C" {

void hbr_default_config(hbr_config* c, int width, int height) {
  c->width = width;
  c->height = height;
  c->temporal_strength = 0.6f;
  c->edge_radius = 0.012f;
  c->edge_eps = 0.0008f;
  c->matte_low = 0.12f;
  c->matte_high = 0.88f;
  c->threads = 0;
  c->decontaminate = 1;
  c->edge_smoothing = 0.8f;
  c->motion_sharpen = 0.85f;
}

hbr_engine* hbr_create(const hbr_config* cfg) {
  if (!cfg || cfg->width < 2 || cfg->height < 2) return nullptr;
  auto* e = new hbr_engine();
  e->cfg = *cfg;
  e->W = cfg->width;
  e->H = cfg->height;
  int hc = static_cast<int>(std::thread::hardware_concurrency());
  e->threads = cfg->threads > 0 ? cfg->threads : std::max(1, std::min(hc, 6));

  // Working resolution: short side ~ 480px (never upscale). The guided
  // filter's *output* is still full resolution because the linear model is
  // applied with the full-res luma.
  int short_side = std::min(e->W, e->H);
  double s = std::max(1.0, short_side / 480.0);
  e->gw = std::max(2, static_cast<int>(std::lround(e->W / s)));
  e->gh = std::max(2, static_cast<int>(std::lround(e->H / s)));
  e->down_x = make_taps(0, e->W, e->W, e->gw);
  e->down_y = make_taps(0, e->H, e->H, e->gh);
  e->up_x = make_taps(0, e->gw, e->gw, e->W);
  e->up_y = make_taps(0, e->gh, e->gh, e->H);

  size_t n = static_cast<size_t>(e->gw) * e->gh;
  for (auto* v : {&e->guide, &e->prev_guide, &e->mask, &e->prev_mask, &e->mI,
                  &e->mP, &e->mIP, &e->mII, &e->a, &e->b, &e->scratch,
                  &e->motion, &e->moving, &e->prev_a, &e->prev_b})
    v->assign(n, 0.f);
  e->alpha.assign(static_cast<size_t>(e->W) * e->H, 0);
  return e;
}

void hbr_destroy(hbr_engine* e) { delete e; }

void hbr_reset(hbr_engine* e) {
  if (e) e->has_prev = e->has_prev_coeffs = e->has_prev_alpha = false;
}

const uint8_t* hbr_alpha(const hbr_engine* e, int* stride) {
  if (!e) return nullptr;
  if (stride) *stride = e->W;
  return e->alpha.data();
}

}  // extern "C"

namespace {

// Samples the low-res mask (in display orientation) for every working-res
// pixel (in storage orientation). Bilinear, normalised coordinates.
template <typename M>
void sample_mask(hbr_engine* e, const M* mask, int mw, int mh, int mstride,
                 float scale, int rot) {
  rot = ((rot % 360) + 360) % 360;
  {
    bool swap = rot == 90 || rot == 270;
    float smw = static_cast<float>(swap ? mh : mw);
    float smh = static_cast<float>(swap ? mw : mh);
    e->mask_px = std::max(e->gw / smw, e->gh / smh);
  }
  for (int y = 0; y < e->gh; ++y) {
    float v = (y + 0.5f) / e->gh;
    float* o = e->mask.data() + static_cast<size_t>(y) * e->gw;
    for (int x = 0; x < e->gw; ++x) {
      float u = (x + 0.5f) / e->gw;
      float du, dv;  // display-normalised coordinates
      switch (rot) {
        case 90: du = 1.f - v; dv = u; break;
        case 180: du = 1.f - u; dv = 1.f - v; break;
        case 270: du = v; dv = 1.f - u; break;
        default: du = u; dv = v; break;
      }
      float sx = clampf(du * mw - 0.5f, 0.f, mw - 1.f);
      float sy = clampf(dv * mh - 0.5f, 0.f, mh - 1.f);
      int x0 = static_cast<int>(sx), y0 = static_cast<int>(sy);
      int x1 = std::min(mw - 1, x0 + 1), y1 = std::min(mh - 1, y0 + 1);
      float fx = sx - x0, fy = sy - y0;
      const M* r0 = mask + static_cast<size_t>(y0) * mstride;
      const M* r1 = mask + static_cast<size_t>(y1) * mstride;
      float top = r0[x0] + (r0[x1] - static_cast<float>(r0[x0])) * fx;
      float bot = r1[x0] + (r1[x1] - static_cast<float>(r1[x0])) * fx;
      o[x] = clampf((top + (bot - top) * fy) * scale, 0.f, 1.f);
    }
  }
}

int refine_common(hbr_engine* e, const uint8_t* y, int y_stride) {
  const size_t n = static_cast<size_t>(e->gw) * e->gh;
  // 1. luma guide at working resolution
  resample_to_float(y, y_stride, 1, e->down_x, e->down_y, 1.f / 255.f,
                    e->guide.data(), e->gw, e->gh, e->threads);

  // 2. scene cut detection -> drop temporal history
  if (e->has_prev) {
    double diff = 0;
    for (size_t i = 0; i < n; ++i)
      diff += std::fabs(e->guide[i] - e->prev_guide[i]);
    if (diff / n > 0.16)
      e->has_prev = e->has_prev_coeffs = e->has_prev_alpha = false;
  }

  // 2b. Remove the model's stair-steps: the mask comes from a ~256 px grid,
  // and bilinear upsampling leaves blocky diagonals. A small Gaussian-like
  // blur (two box passes) at about half a mask pixel makes the outline
  // round before the guided filter snaps it to the real edges.
  float es = clampf(e->cfg.edge_smoothing, 0.f, 1.f);
  {
    int sr = static_cast<int>(std::lround(e->mask_px * (0.25f + 0.5f * es)));
    if (sr > 0) {
      box_mean(e->mask.data(), e->scratch.data(), e->gw, e->gh, sr, e->tmp);
      box_mean(e->scratch.data(), e->mask.data(), e->gw, e->gh, sr, e->tmp);
    }
  }

  // 3. motion-adaptive temporal smoothing. Small frame-to-frame changes in
  // the mask are model jitter and get averaged; large changes are real
  // motion and pass straight through so moving limbs do not ghost.
  float k = clampf(e->cfg.temporal_strength, 0.f, 1.f);
  if (e->has_prev) {
    float base = 1.f - 0.85f * k;
    for (size_t i = 0; i < n; ++i) {
      float cur = e->mask[i], prev = e->prev_mask[i];
      float d = std::fabs(cur - prev);
      // the image itself changing (motion) also counts, not only the mask:
      // a moving arm must not drag a semi-transparent copy of where it was
      float dg = std::fabs(e->guide[i] - e->prev_guide[i]) * 2.5f;
      float mv = std::max(d, dg);
      float w = base + (1.f - base) * smoothstep(0.06f, 0.3f, mv);
      e->mask[i] = prev + w * (cur - prev);
      e->motion[i] = w;
      e->moving[i] = smoothstep(0.04f, 0.2f, mv);
    }
    // Spread the motion map over the edge band (a couple of mask pixels):
    // the band is where the halo shows, and it trails the moving edge.
    int mr = std::max(1, static_cast<int>(std::lround(2.f * e->mask_px)));
    box_mean(e->moving.data(), e->scratch.data(), e->gw, e->gh, mr, e->tmp);
    for (size_t i = 0; i < n; ++i) e->moving[i] = std::min(1.f, 2.f * e->scratch[i]);
  } else {
    std::fill(e->motion.begin(), e->motion.end(), 1.f);
    std::fill(e->moving.begin(), e->moving.end(), 0.f);
  }
  std::memcpy(e->prev_mask.data(), e->mask.data(), n * sizeof(float));
  std::memcpy(e->prev_guide.data(), e->guide.data(), n * sizeof(float));
  e->has_prev = true;

  // 4. fast guided filter (He & Sun 2015) at working resolution
  int short_g = std::min(e->gw, e->gh);
  // The window must cover the model's soft edge (about 2-3 mask pixels) or
  // the filter cannot pull the matte onto the real edge.
  int r = std::max(1, static_cast<int>(std::lround(std::max(
                          e->cfg.edge_radius * short_g, 2.5f * e->mask_px))));
  float eps = std::max(1e-6f, e->cfg.edge_eps);
  const float* I = e->guide.data();
  const float* P = e->mask.data();
  float* s = e->scratch.data();
  box_mean(I, e->mI.data(), e->gw, e->gh, r, e->tmp);
  box_mean(P, e->mP.data(), e->gw, e->gh, r, e->tmp);
  for (size_t i = 0; i < n; ++i) s[i] = I[i] * P[i];
  box_mean(s, e->mIP.data(), e->gw, e->gh, r, e->tmp);
  for (size_t i = 0; i < n; ++i) s[i] = I[i] * I[i];
  box_mean(s, e->mII.data(), e->gw, e->gh, r, e->tmp);
  for (size_t i = 0; i < n; ++i) {
    float mi = e->mI[i];
    float var = e->mII[i] - mi * mi;
    float cov = e->mIP[i] - mi * e->mP[i];
    float av = cov / (var + eps);
    e->a[i] = av;
    e->b[i] = e->mP[i] - av * mi;
  }
  box_mean(e->a.data(), e->mI.data(), e->gw, e->gh, r, e->tmp);  // mean a
  box_mean(e->b.data(), e->mP.data(), e->gw, e->gh, r, e->tmp);  // mean b
  // 4b. Steady outline: luma noise makes the guided-filter coefficients
  // shimmer from frame to frame even when nothing moves. Average them over
  // time where the picture is static; let them follow instantly where it
  // moves (same motion weights as the mask).
  if (e->has_prev_coeffs && es > 0.f) {
    for (size_t i = 0; i < n; ++i) {
      float w = 1.f - es * (1.f - e->motion[i]);
      e->mI[i] = e->prev_a[i] + w * (e->mI[i] - e->prev_a[i]);
      e->mP[i] = e->prev_b[i] + w * (e->mP[i] - e->prev_b[i]);
    }
  }
  std::memcpy(e->prev_a.data(), e->mI.data(), n * sizeof(float));
  std::memcpy(e->prev_b.data(), e->mP.data(), n * sizeof(float));
  e->has_prev_coeffs = true;
  const float* MA = e->mI.data();
  const float* MB = e->mP.data();

  // 4c. Sensor noise in the full-res luma would otherwise go straight into
  // the matte (q = a*I + b) and make edges sparkle. Blend in a 3x3 mean of
  // the luma; real edges are wider than a pixel, so they stay put.
  const int Wf = e->W, Hf = e->H;
  const uint8_t* guide_full = y;
  int guide_stride = y_stride;
  if (es > 0.f) {
    e->luma_dn.resize(static_cast<size_t>(Wf) * Hf);
    const int wgt = static_cast<int>(es * 256.f);
    parallel_for(Hf, e->threads, [&](int yb, int ye) {
      for (int yy = yb; yy < ye; ++yy) {
        const uint8_t* r0 = y + static_cast<size_t>(std::max(0, yy - 1)) * y_stride;
        const uint8_t* r1 = y + static_cast<size_t>(yy) * y_stride;
        const uint8_t* r2 = y + static_cast<size_t>(std::min(Hf - 1, yy + 1)) * y_stride;
        uint8_t* o = e->luma_dn.data() + static_cast<size_t>(yy) * Wf;
        for (int x = 0; x < Wf; ++x) {
          int xl = std::max(0, x - 1), xr = std::min(Wf - 1, x + 1);
          int sum = r0[xl] + r0[x] + r0[xr] + r1[xl] + r1[x] + r1[xr] + r2[xl] +
                    r2[x] + r2[xr];
          int mean = (sum * 455) >> 12;  // /9
          int v = r1[x];
          o[x] = static_cast<uint8_t>(v + (((mean - v) * wgt) >> 8));
        }
      }
    });
    guide_full = e->luma_dn.data();
    guide_stride = Wf;
  }
  const bool temporal_full = e->has_prev_alpha && es > 0.f;
  if (e->prev_alpha.size() != e->alpha.size()) e->prev_alpha.assign(e->alpha.size(), 0);

  // 5. apply q = a*I + b at FULL resolution, then tighten the matte
  float lo = e->cfg.matte_low, hi = e->cfg.matte_high;
  if (hi <= lo + 1e-3f) hi = lo + 1e-3f;
  float sc = 255.f / (255.f * (hi - lo));  // takes I in 0..255
  float lo255 = lo * 255.f;
  const int W = e->W, gw = e->gw;
  const float sharpen = 3.f * clampf(e->cfg.motion_sharpen, 0.f, 1.f);
  parallel_for(e->H, e->threads, [&](int yb, int ye) {
    std::vector<float> ra(gw), rb(gw);
    for (int yy = yb; yy < ye; ++yy) {
      // vertical interpolation of the coefficient rows
      const float* wv = e->up_y.w.data() + e->up_y.offset[yy];
      int y0 = e->up_y.start[yy], cnt = e->up_y.count[yy];
      for (int x = 0; x < gw; ++x) {
        float av = 0, bv = 0;
        for (int k2 = 0; k2 < cnt; ++k2) {
          av += wv[k2] * MA[static_cast<size_t>(y0 + k2) * gw + x];
          bv += wv[k2] * MB[static_cast<size_t>(y0 + k2) * gw + x];
        }
        ra[x] = av;
        rb[x] = bv * 255.f;  // b is in mask units; scale to I in 0..255
      }
      const uint8_t* iy = guide_full + static_cast<size_t>(yy) * guide_stride;
      uint8_t* out = e->alpha.data() + static_cast<size_t>(yy) * W;
      uint8_t* pa = e->prev_alpha.data() + static_cast<size_t>(yy) * W;
      const float* mrow = e->motion.data() + static_cast<size_t>(y0) * gw;
      const float* mvrow = e->moving.data() + static_cast<size_t>(y0) * gw;
      for (int x = 0; x < W; ++x) {
        const float* wx = e->up_x.w.data() + e->up_x.offset[x];
        int x0 = e->up_x.start[x];
        float av = ra[x0] * wx[0], bv = rb[x0] * wx[0];
        if (e->up_x.count[x] > 1) {
          av += ra[x0 + 1] * wx[1];
          bv += rb[x0 + 1] * wx[1];
        }
        float q = av * iy[x] + bv;  // 0..255 range
        // smooth (C1) roll-off instead of a hard clamp: no visible kink
        // where the soft edge meets fully opaque / fully clear pixels
        float t = clampf((q - lo255) * sc * (1.f / 255.f), 0.f, 1.f);
        if (sharpen > 0.f) {
          // Moving edges: a narrower transition, so the pixel is either the
          // person or the new background instead of a blurry mix of both.
          float m = mvrow[x0];
          if (m > 0.f) t = clampf(0.5f + (t - 0.5f) * (1.f + sharpen * m), 0.f, 1.f);
        }
        float av255 = t * t * (3.f - 2.f * t) * 255.f;
        if (temporal_full) {
          // steady edges where the picture is static, instant where it moves
          float w = 1.f - es * (1.f - mrow[x0]);
          av255 = pa[x] + w * (av255 - pa[x]);
        }
        out[x] = static_cast<uint8_t>(av255 + 0.5f);
        pa[x] = out[x];
      }
    }
  });
  e->has_prev_alpha = true;
  return HBR_OK;
}

// Builds local colour estimates used to "un-mix" semi-transparent edge
// pixels. For each pixel near the outline we need (a) the colour of the
// person nearby and (b) the colour of the ORIGINAL background nearby.
// Both come from normalised convolution weighted by solid foreground /
// solid background pixels only, at ~360 px on the short side.
void build_decon(hbr_engine* e, const hbr_yuv* src) {
  const int W = e->W, H = e->H, CW = (W + 1) / 2, CH = (H + 1) / 2;
  if (e->ew == 0) {
    double ds = std::max(1.0, std::min(W, H) / 360.0);
    e->ew = std::max(2, static_cast<int>(std::lround(W / ds)));
    e->eh = std::max(2, static_cast<int>(std::lround(H / ds)));
    e->ex_l = make_taps(0, e->ew, e->ew, W);
    e->ey_l = make_taps(0, e->eh, e->eh, H);
    e->ex_c = make_taps(0, e->ew, e->ew, CW);
    e->ey_c = make_taps(0, e->eh, e->eh, CH);
  }
  const int ew = e->ew, eh = e->eh, th = e->threads;
  const size_t n = static_cast<size_t>(ew) * eh;
  Taps lx = make_taps(0, W, W, ew), ly = make_taps(0, H, H, eh);
  Taps cx = make_taps(0, CW, CW, ew), cy = make_taps(0, CH, CH, eh);
  std::vector<float> pl[3], al(n), wf(n), wb(n), t1(n), t2(n), tmp;
  for (auto& p : pl) p.resize(n);
  resample_to_float(src->y, src->y_stride, 1, lx, ly, 1.f, pl[0].data(), ew, eh, th);
  resample_to_float(src->u, src->uv_stride, src->uv_pixel_stride, cx, cy, 1.f,
                    pl[1].data(), ew, eh, th);
  resample_to_float(src->v, src->uv_stride, src->uv_pixel_stride, cx, cy, 1.f,
                    pl[2].data(), ew, eh, th);
  resample_to_float(e->alpha.data(), W, 1, lx, ly, 1.f / 255.f, al.data(), ew,
                    eh, th);
  for (size_t i = 0; i < n; ++i) {
    wf[i] = smoothstep(0.985f, 1.f, al[i]);
    wb[i] = smoothstep(0.985f, 1.f, 1.f - al[i]);
  }
  int r = std::max(1, static_cast<int>(std::lround(std::min(ew, eh) * 0.02)));
  auto blur2 = [&](std::vector<float>& v) {
    box_mean(v.data(), t1.data(), ew, eh, r, tmp);
    box_mean(t1.data(), v.data(), ew, eh, r, tmp);
  };
  std::vector<float> df = wf, db = wb;
  blur2(df);
  blur2(db);
  const float fb = 1e-3f;
  for (int c = 0; c < 3; ++c) {
    std::vector<float> plain = pl[c];
    blur2(plain);
    e->fgp[c].resize(n);
    e->bgp[c].resize(n);
    for (size_t i = 0; i < n; ++i) e->fgp[c][i] = pl[c][i] * wf[i];
    for (size_t i = 0; i < n; ++i) e->bgp[c][i] = pl[c][i] * wb[i];
    blur2(e->fgp[c]);
    blur2(e->bgp[c]);
    for (size_t i = 0; i < n; ++i) {
      e->fgp[c][i] = (e->fgp[c][i] + fb * plain[i]) / (df[i] + fb);
      e->bgp[c][i] = (e->bgp[c][i] + fb * plain[i]) / (db[i] + fb);
    }
  }
}

inline float sample_est(const std::vector<float>& p, int ew, const Taps& tx,
                        const Taps& ty, int x, int y) {
  int x0 = tx.start[x], y0 = ty.start[y];
  float wx = tx.count[x] > 1 ? tx.w[tx.offset[x] + 1] : 0.f;
  float wy = ty.count[y] > 1 ? ty.w[ty.offset[y] + 1] : 0.f;
  int x1 = x0 + (tx.count[x] > 1 ? 1 : 0), y1 = y0 + (ty.count[y] > 1 ? 1 : 0);
  const float* r0 = p.data() + static_cast<size_t>(y0) * ew;
  const float* r1 = p.data() + static_cast<size_t>(y1) * ew;
  float top = r0[x0] + (r0[x1] - r0[x0]) * wx;
  float bot = r1[x0] + (r1[x1] - r1[x0]) * wx;
  return top + (bot - top) * wy;
}

// Recovers the pure foreground colour of a semi-transparent edge pixel.
// Model: I = t*F + (1-t)*B_old, with F and B_old the nearby person and
// original-background colours. The mixing fraction t is estimated from the
// luma (the matte alpha is deliberately tightened, so it under-reports
// mixing) and reused for chroma, so all three channels are corrected
// consistently and no false colours appear. The old background's share is
// swapped for the person colour while keeping the pixel's own detail.
inline float mix_fraction(int I, float a, float fg, float bg_old) {
  float d = fg - bg_old;
  if (std::fabs(d) < 12.f) return a;  // luma can't tell them apart
  return clampf((I - bg_old) / d, 0.f, 1.f);
}

inline int unmix(int I, float a, float t, float fg, float bg_old) {
  float F = I + (1.f - t) * (fg - bg_old);
  F = clampf(F, std::min<float>(I, fg), std::max<float>(I, fg));
  float w = 1.f - smoothstep(0.97f, 1.f, a);
  return static_cast<int>(clampf(I + w * (F - I), 0.f, 255.f) + 0.5f);
}

// Blend helper: (s*a + b*(255-a)) / 255 with rounding.
inline uint8_t blend(int s, int b, int a) {
  int v = s * a + b * (255 - a) + 127;
  return static_cast<uint8_t>((v + (v >> 8) + 1) >> 8);
}

template <typename BgY, typename BgUV>
int composite(hbr_engine* e, const hbr_yuv* src, hbr_yuv* dst, BgY bgy,
              BgUV bguv) {
  if (!src || !dst || !src->y || !dst->y) return HBR_ERR_ARG;
  const int W = e->W, H = e->H;
  const uint8_t* A = e->alpha.data();
  const bool dc = e->cfg.decontaminate != 0;
  if (dc) build_decon(e, src);  // reads src before any in-place write
  if (dc) e->mixfrac.resize(static_cast<size_t>(W) * H);
  uint8_t* T = dc ? e->mixfrac.data() : nullptr;
  if (dc) e->alpha_eff.resize(static_cast<size_t>(W) * H);
  uint8_t* AE = dc ? e->alpha_eff.data() : nullptr;
  const int ew = e->ew;
  parallel_for(H, e->threads, [&](int b, int en) {
    for (int y = b; y < en; ++y) {
      const uint8_t* s = src->y + static_cast<size_t>(y) * src->y_stride;
      uint8_t* d = dst->y + static_cast<size_t>(y) * dst->y_stride;
      const uint8_t* a = A + static_cast<size_t>(y) * W;
      for (int x = 0; x < W; ++x) {
        int av = a[x];
        int sv = s[x];
        if (dc && av > 0 && av < 255) {
          float af = av / 255.f;
          float fg = sample_est(e->fgp[0], ew, e->ex_l, e->ey_l, x, y);
          float bo = sample_est(e->bgp[0], ew, e->ex_l, e->ey_l, x, y);
          float t = mix_fraction(sv, af, fg, bo);
          // Where the colours clearly say "this is the old background" but
          // the model was unsure, trust the colours: lower the opacity so
          // no ghost or colour smear of either layer remains.
          if (std::fabs(fg - bo) >= 24.f) {
            float lim = t + 0.2f;
            if (af > lim) {
              af = lim;
              av = static_cast<int>(af * 255.f + 0.5f);
            }
          }
          T[static_cast<size_t>(y) * W + x] = static_cast<uint8_t>(t * 255.f + 0.5f);
          AE[static_cast<size_t>(y) * W + x] = static_cast<uint8_t>(av);
          sv = unmix(sv, af, t, fg, bo);
        } else if (dc) {
          T[static_cast<size_t>(y) * W + x] = static_cast<uint8_t>(av);
          AE[static_cast<size_t>(y) * W + x] = static_cast<uint8_t>(av);
        }
        d[x] = blend(sv, bgy(x, y), av);
      }
    }
  });
  const int CW = (W + 1) / 2, CH = (H + 1) / 2;
  parallel_for(CH, e->threads, [&](int b, int en) {
    for (int cy = b; cy < en; ++cy) {
      int y0 = 2 * cy, y1 = std::min(H - 1, y0 + 1);
      const uint8_t* AC = dc ? AE : A;
      const uint8_t* a0 = AC + static_cast<size_t>(y0) * W;
      const uint8_t* a1 = AC + static_cast<size_t>(y1) * W;
      const size_t so = static_cast<size_t>(cy) * src->uv_stride;
      const size_t dof = static_cast<size_t>(cy) * dst->uv_stride;
      const int sp = src->uv_pixel_stride, dp = dst->uv_pixel_stride;
      for (int cx = 0; cx < CW; ++cx) {
        int x0 = 2 * cx, x1 = std::min(W - 1, x0 + 1);
        int ac = (a0[x0] + a0[x1] + a1[x0] + a1[x1] + 2) >> 2;
        uint8_t bu, bv;
        bguv(cx, cy, &bu, &bv);
        int su = src->u[so + static_cast<size_t>(cx) * sp];
        int sv = src->v[so + static_cast<size_t>(cx) * sp];
        if (dc && ac > 0 && ac < 255) {
          float af = ac / 255.f;
          const uint8_t* t0 = T + static_cast<size_t>(y0) * W;
          const uint8_t* t1 = T + static_cast<size_t>(y1) * W;
          float t = (t0[x0] + t0[x1] + t1[x0] + t1[x1]) / (4.f * 255.f);
          su = unmix(su, af, t, sample_est(e->fgp[1], ew, e->ex_c, e->ey_c, cx, cy),
                     sample_est(e->bgp[1], ew, e->ex_c, e->ey_c, cx, cy));
          sv = unmix(sv, af, t, sample_est(e->fgp[2], ew, e->ex_c, e->ey_c, cx, cy),
                     sample_est(e->bgp[2], ew, e->ex_c, e->ey_c, cx, cy));
        }
        dst->u[dof + static_cast<size_t>(cx) * dp] = blend(su, bu, ac);
        dst->v[dof + static_cast<size_t>(cx) * dp] = blend(sv, bv, ac);
      }
    }
  });
  return HBR_OK;
}

}  // namespace

extern "C" {

int hbr_refine_u8(hbr_engine* e, const uint8_t* y, int y_stride,
                  const uint8_t* mask, int mw, int mh, int mstride, int rot) {
  if (!e || !y || !mask || mw < 1 || mh < 1) return HBR_ERR_ARG;
  sample_mask(e, mask, mw, mh, mstride, 1.f / 255.f, rot);
  return refine_common(e, y, y_stride);
}

int hbr_refine_f32(hbr_engine* e, const uint8_t* y, int y_stride,
                   const float* mask, int mw, int mh, int mstride, int rot) {
  if (!e || !y || !mask || mw < 1 || mh < 1) return HBR_ERR_ARG;
  sample_mask(e, mask, mw, mh, mstride, 1.f, rot);
  return refine_common(e, y, y_stride);
}

int hbr_composite_color(hbr_engine* e, const hbr_yuv* src, hbr_yuv* dst,
                        uint8_t y, uint8_t u, uint8_t v) {
  if (!e) return HBR_ERR_ARG;
  return composite(
      e, src, dst, [y](int, int) { return y; },
      [u, v](int, int, uint8_t* bu, uint8_t* bv) {
        *bu = u;
        *bv = v;
      });
}

int hbr_composite_image(hbr_engine* e, const hbr_yuv* src, const hbr_yuv* bg,
                        hbr_yuv* dst) {
  if (!e || !bg || !bg->y) return HBR_ERR_ARG;
  return composite(
      e, src, dst,
      [bg](int x, int y) {
        return bg->y[static_cast<size_t>(y) * bg->y_stride + x];
      },
      [bg](int cx, int cy, uint8_t* bu, uint8_t* bv) {
        size_t o = static_cast<size_t>(cy) * bg->uv_stride +
                   static_cast<size_t>(cx) * bg->uv_pixel_stride;
        *bu = bg->u[o];
        *bv = bg->v[o];
      });
}

int hbr_composite_blur(hbr_engine* e, const hbr_yuv* src, hbr_yuv* dst,
                       float amount) {
  if (!e || !src || !src->y) return HBR_ERR_ARG;
  const int W = e->W, H = e->H, CW = (W + 1) / 2, CH = (H + 1) / 2;
  // Blur at a reduced resolution (short side ~ 270): a heavy blur has no
  // high frequencies, so this is visually identical and ~20x cheaper.
  int short_side = std::min(W, H);
  double ds = std::max(1.0, short_side / 270.0);
  int bw = std::max(2, static_cast<int>(std::lround(W / ds)));
  int bh = std::max(2, static_cast<int>(std::lround(H / ds)));
  int th = e->threads;
  size_t n = static_cast<size_t>(bw) * bh;
  std::vector<float> py(n), pu(n), pv(n), wgt(n), t1(n), t2(n), tmp;

  Taps lx = make_taps(0, W, W, bw), ly = make_taps(0, H, H, bh);
  Taps cx = make_taps(0, CW, CW, bw), cy = make_taps(0, CH, CH, bh);
  resample_to_float(src->y, src->y_stride, 1, lx, ly, 1.f, py.data(), bw, bh,
                    th);
  resample_to_float(src->u, src->uv_stride, src->uv_pixel_stride, cx, cy, 1.f,
                    pu.data(), bw, bh, th);
  resample_to_float(src->v, src->uv_stride, src->uv_pixel_stride, cx, cy, 1.f,
                    pv.data(), bw, bh, th);
  resample_to_float(e->alpha.data(), W, 1, lx, ly, 1.f / 255.f, wgt.data(), bw,
                    bh, th);
  // background weight; slightly eroded person so edge pixels don't leak in
  for (auto& w : wgt) w = clampf(1.f - w * 1.25f, 0.f, 1.f);

  int r = std::max(1, static_cast<int>(std::lround(
                          clampf(amount, 0.f, 0.2f) * std::min(bw, bh) / 1.7)));
  auto blur3 = [&](std::vector<float>& v) {
    box_mean(v.data(), t1.data(), bw, bh, r, tmp);
    box_mean(t1.data(), t2.data(), bw, bh, r, tmp);
    box_mean(t2.data(), v.data(), bw, bh, r, tmp);
  };
  std::vector<float> den = wgt;
  blur3(den);
  const float fb = 1e-3f;  // fallback to plain blur deep inside the person
  for (auto* plane : {&py, &pu, &pv}) {
    std::vector<float> plain = *plane;
    blur3(plain);
    std::vector<float> num(n);
    for (size_t i = 0; i < n; ++i) num[i] = (*plane)[i] * wgt[i];
    blur3(num);
    for (size_t i = 0; i < n; ++i)
      (*plane)[i] = (num[i] + fb * plain[i]) / (den[i] + fb);
  }

  // upsample to full res into the internal background buffer
  e->blur_y.resize(static_cast<size_t>(W) * H);
  e->blur_u.resize(static_cast<size_t>(CW) * CH);
  e->blur_v.resize(static_cast<size_t>(CW) * CH);
  auto upsample = [&](const std::vector<float>& p, uint8_t* out, int ow,
                      int oh) {
    Taps ux = make_taps(0, bw, bw, ow), uy = make_taps(0, bh, bh, oh);
    std::vector<float> f(static_cast<size_t>(ow) * oh);
    resample_to_float(p.data(), bw, 1, ux, uy, 1.f, f.data(), ow, oh, th);
    for (size_t i = 0; i < f.size(); ++i) out[i] = to_u8(f[i]);
  };
  upsample(py, e->blur_y.data(), W, H);
  upsample(pu, e->blur_u.data(), CW, CH);
  upsample(pv, e->blur_v.data(), CW, CH);
  hbr_yuv bg{e->blur_y.data(), W, e->blur_u.data(), e->blur_v.data(), CW, 1};
  return hbr_composite_image(e, src, &bg, dst);
}

void hbr_rgb_to_yuv(uint8_t r, uint8_t g, uint8_t b, hbr_matrix m,
                    int full_range, uint8_t* y, uint8_t* u, uint8_t* v) {
  float fy, fu, fv;
  rgbf_to_yuv(r / 255.f, g / 255.f, b / 255.f, m, full_range, &fy, &fu, &fv);
  *y = to_u8(fy);
  *u = to_u8(fu);
  *v = to_u8(fv);
}

namespace {
// Aspect-fill crop window of a sw x sh source for a dw x dh target.
void fill_window(int sw, int sh, int dw, int dh, double* x0, double* y0,
                 double* cw, double* ch) {
  double scale = std::max(static_cast<double>(dw) / sw,
                          static_cast<double>(dh) / sh);
  *cw = dw / scale;
  *ch = dh / scale;
  *x0 = (sw - *cw) / 2.0;
  *y0 = (sh - *ch) / 2.0;
}
}  // namespace

int hbr_rgba_to_yuv_fill(const uint8_t* rgba, int w, int h, int stride,
                         hbr_yuv* dst, int dw, int dh, hbr_matrix m,
                         int full_range) {
  if (!rgba || !dst || w < 1 || h < 1 || dw < 2 || dh < 2) return HBR_ERR_ARG;
  double x0, y0, cw, ch;
  fill_window(w, h, dw, dh, &x0, &y0, &cw, &ch);
  Taps tx = make_taps(x0, cw, w, dw), ty = make_taps(y0, ch, h, dh);
  size_t n = static_cast<size_t>(dw) * dh;
  std::vector<float> R(n), G(n), B(n);
  int th = static_cast<int>(std::max(1u, std::thread::hardware_concurrency()));
  resample_to_float(rgba + 0, stride, 4, tx, ty, 1.f / 255.f, R.data(), dw, dh,
                    th);
  resample_to_float(rgba + 1, stride, 4, tx, ty, 1.f / 255.f, G.data(), dw, dh,
                    th);
  resample_to_float(rgba + 2, stride, 4, tx, ty, 1.f / 255.f, B.data(), dw, dh,
                    th);
  const int CW = (dw + 1) / 2, CH = (dh + 1) / 2;
  for (int y = 0; y < dh; ++y)
    for (int x = 0; x < dw; ++x) {
      size_t i = static_cast<size_t>(y) * dw + x;
      float fy, fu, fv;
      rgbf_to_yuv(R[i], G[i], B[i], m, full_range, &fy, &fu, &fv);
      dst->y[static_cast<size_t>(y) * dst->y_stride + x] = to_u8(fy);
    }
  for (int cy = 0; cy < CH; ++cy)
    for (int cx = 0; cx < CW; ++cx) {
      float r = 0, g = 0, b = 0;
      int cnt = 0;
      for (int dy = 0; dy < 2; ++dy)
        for (int dx = 0; dx < 2; ++dx) {
          int xx = std::min(dw - 1, 2 * cx + dx);
          int yy = std::min(dh - 1, 2 * cy + dy);
          size_t i = static_cast<size_t>(yy) * dw + xx;
          r += R[i];
          g += G[i];
          b += B[i];
          ++cnt;
        }
      float fy, fu, fv;
      rgbf_to_yuv(r / cnt, g / cnt, b / cnt, m, full_range, &fy, &fu, &fv);
      size_t o = static_cast<size_t>(cy) * dst->uv_stride +
                 static_cast<size_t>(cx) * dst->uv_pixel_stride;
      dst->u[o] = to_u8(fu);
      dst->v[o] = to_u8(fv);
    }
  return HBR_OK;
}

int hbr_scale_yuv_fill(const hbr_yuv* src, int sw, int sh, hbr_yuv* dst,
                       int dw, int dh) {
  if (!src || !dst || sw < 2 || sh < 2 || dw < 2 || dh < 2) return HBR_ERR_ARG;
  int th = static_cast<int>(std::max(1u, std::thread::hardware_concurrency()));
  double x0, y0, cw, ch;
  fill_window(sw, sh, dw, dh, &x0, &y0, &cw, &ch);
  {
    Taps tx = make_taps(x0, cw, sw, dw), ty = make_taps(y0, ch, sh, dh);
    std::vector<float> f(static_cast<size_t>(dw) * dh);
    resample_to_float(src->y, src->y_stride, 1, tx, ty, 1.f, f.data(), dw, dh,
                      th);
    for (int y = 0; y < dh; ++y)
      for (int x = 0; x < dw; ++x)
        dst->y[static_cast<size_t>(y) * dst->y_stride + x] =
            to_u8(f[static_cast<size_t>(y) * dw + x]);
  }
  const int SCW = (sw + 1) / 2, SCH = (sh + 1) / 2;
  const int DCW = (dw + 1) / 2, DCH = (dh + 1) / 2;
  Taps tx = make_taps(x0 / 2, cw / 2, SCW, DCW);
  Taps ty = make_taps(y0 / 2, ch / 2, SCH, DCH);
  std::vector<float> fu(static_cast<size_t>(DCW) * DCH), fv(fu.size());
  resample_to_float(src->u, src->uv_stride, src->uv_pixel_stride, tx, ty, 1.f,
                    fu.data(), DCW, DCH, th);
  resample_to_float(src->v, src->uv_stride, src->uv_pixel_stride, tx, ty, 1.f,
                    fv.data(), DCW, DCH, th);
  for (int y = 0; y < DCH; ++y)
    for (int x = 0; x < DCW; ++x) {
      size_t o = static_cast<size_t>(y) * dst->uv_stride +
                 static_cast<size_t>(x) * dst->uv_pixel_stride;
      dst->u[o] = to_u8(fu[static_cast<size_t>(y) * DCW + x]);
      dst->v[o] = to_u8(fv[static_cast<size_t>(y) * DCW + x]);
    }
  return HBR_OK;
}

void hbr_place_rect(int img_w, int img_h, int canvas_w, int canvas_h, int fit,
                    float scale, float pan_x, float pan_y, int* rx, int* ry,
                    int* rw, int* rh) {
  double sx = static_cast<double>(canvas_w) / std::max(1, img_w);
  double sy = static_cast<double>(canvas_h) / std::max(1, img_h);
  double s = (fit ? std::min(sx, sy) : std::max(sx, sy)) *
             clampf(scale, 0.05f, 20.f);
  int w = std::max(2, static_cast<int>(std::lround(img_w * s / 2.0)) * 2);
  int h = std::max(2, static_cast<int>(std::lround(img_h * s / 2.0)) * 2);
  // pan across the free range (works for both larger and smaller images)
  double fx = (canvas_w - w) / 2.0, fy = (canvas_h - h) / 2.0;
  // pan -1 aligns the left/top edges, +1 the right/bottom edges
  double x = fx * (1.0 + clampf(pan_x, -1.f, 1.f));
  double y = fy * (1.0 + clampf(pan_y, -1.f, 1.f));
  *rx = static_cast<int>(std::lround(x / 2.0)) * 2;
  *ry = static_cast<int>(std::lround(y / 2.0)) * 2;
  *rw = w;
  *rh = h;
}

namespace {
// One plane: src (sw x sh, pixel step sp) -> dst rect, clipped.
void blit_plane(const uint8_t* s, int ss, int sp, int sw, int sh, uint8_t* d,
                int ds, int dp, int dw, int dh, double rx, double ry, double rw,
                double rh, int th) {
  int x0 = std::max(0, static_cast<int>(std::ceil(rx - 1e-9)));
  int y0 = std::max(0, static_cast<int>(std::ceil(ry - 1e-9)));
  int x1 = std::min(dw, static_cast<int>(std::floor(rx + rw + 1e-9)));
  int y1 = std::min(dh, static_cast<int>(std::floor(ry + rh + 1e-9)));
  if (x1 <= x0 || y1 <= y0) return;
  const double fx = sw / rw, fy = sh / rh;
  Taps tx = make_taps((x0 - rx) * fx, (x1 - x0) * fx, sw, x1 - x0);
  Taps ty = make_taps((y0 - ry) * fy, (y1 - y0) * fy, sh, y1 - y0);
  int ow = x1 - x0, oh = y1 - y0;
  std::vector<float> f(static_cast<size_t>(ow) * oh);
  resample_to_float(s, ss, sp, tx, ty, 1.f, f.data(), ow, oh, th);
  for (int y = 0; y < oh; ++y) {
    uint8_t* o = d + static_cast<size_t>(y0 + y) * ds + static_cast<size_t>(x0) * dp;
    const float* fr = f.data() + static_cast<size_t>(y) * ow;
    for (int x = 0; x < ow; ++x) o[static_cast<size_t>(x) * dp] = to_u8(fr[x]);
  }
}

int hw_threads() {
  return static_cast<int>(std::max(1u, std::min(6u, std::thread::hardware_concurrency())));
}
}  // namespace

int hbr_blit_yuv(const hbr_yuv* src, int sw, int sh, hbr_yuv* dst, int dw,
                 int dh, int rx, int ry, int rw, int rh) {
  if (!src || !dst || sw < 2 || sh < 2 || dw < 2 || dh < 2 || rw < 2 || rh < 2)
    return HBR_ERR_ARG;
  int th = hw_threads();
  blit_plane(src->y, src->y_stride, 1, sw, sh, dst->y, dst->y_stride, 1, dw, dh,
             rx, ry, rw, rh, th);
  int scw = (sw + 1) / 2, sch = (sh + 1) / 2, dcw = (dw + 1) / 2, dch = (dh + 1) / 2;
  blit_plane(src->u, src->uv_stride, src->uv_pixel_stride, scw, sch, dst->u,
             dst->uv_stride, dst->uv_pixel_stride, dcw, dch, rx / 2.0, ry / 2.0,
             rw / 2.0, rh / 2.0, th);
  blit_plane(src->v, src->uv_stride, src->uv_pixel_stride, scw, sch, dst->v,
             dst->uv_stride, dst->uv_pixel_stride, dcw, dch, rx / 2.0, ry / 2.0,
             rw / 2.0, rh / 2.0, th);
  return HBR_OK;
}

int hbr_crop_yuv(const hbr_yuv* src, int sw, int sh, int rx, int ry, int rw,
                 int rh, hbr_yuv* dst, int dw, int dh) {
  if (!src || !dst || sw < 2 || sh < 2 || dw < 2 || dh < 2 || rw < 2 || rh < 2)
    return HBR_ERR_ARG;
  int th = hw_threads();
  auto plane = [&](const uint8_t* s, int ss, int sp, int pw, int ph, uint8_t* d,
                   int ds, int dp, int ow, int oh, double x, double y, double w,
                   double h) {
    Taps tx = make_taps(x, w, pw, ow), ty = make_taps(y, h, ph, oh);
    std::vector<float> f(static_cast<size_t>(ow) * oh);
    resample_to_float(s, ss, sp, tx, ty, 1.f, f.data(), ow, oh, th);
    for (int yy = 0; yy < oh; ++yy) {
      uint8_t* o = d + static_cast<size_t>(yy) * ds;
      const float* fr = f.data() + static_cast<size_t>(yy) * ow;
      for (int xx = 0; xx < ow; ++xx) o[static_cast<size_t>(xx) * dp] = to_u8(fr[xx]);
    }
  };
  plane(src->y, src->y_stride, 1, sw, sh, dst->y, dst->y_stride, 1, dw, dh, rx,
        ry, rw, rh);
  int scw = (sw + 1) / 2, sch = (sh + 1) / 2, dcw = (dw + 1) / 2, dch = (dh + 1) / 2;
  plane(src->u, src->uv_stride, src->uv_pixel_stride, scw, sch, dst->u,
        dst->uv_stride, dst->uv_pixel_stride, dcw, dch, rx / 2.0, ry / 2.0,
        rw / 2.0, rh / 2.0);
  plane(src->v, src->uv_stride, src->uv_pixel_stride, scw, sch, dst->v,
        dst->uv_stride, dst->uv_pixel_stride, dcw, dch, rx / 2.0, ry / 2.0,
        rw / 2.0, rh / 2.0);
  return HBR_OK;
}

int hbr_fill_yuv(hbr_yuv* dst, int w, int h, uint8_t y, uint8_t u, uint8_t v) {
  if (!dst || w < 1 || h < 1) return HBR_ERR_ARG;
  for (int r = 0; r < h; ++r)
    std::memset(dst->y + static_cast<size_t>(r) * dst->y_stride, y, w);
  int cw = (w + 1) / 2, ch = (h + 1) / 2;
  for (int r = 0; r < ch; ++r)
    for (int c = 0; c < cw; ++c) {
      size_t o = static_cast<size_t>(r) * dst->uv_stride +
                 static_cast<size_t>(c) * dst->uv_pixel_stride;
      dst->u[o] = u;
      dst->v[o] = v;
    }
  return HBR_OK;
}

int hbr_blur_yuv(hbr_yuv* img, int w, int h, float amount) {
  if (!img || w < 2 || h < 2) return HBR_ERR_ARG;
  int th = hw_threads();
  double ds = std::max(1.0, std::min(w, h) / 270.0);
  int bw = std::max(2, static_cast<int>(std::lround(w / ds)));
  int bh = std::max(2, static_cast<int>(std::lround(h / ds)));
  int r = std::max(1, static_cast<int>(std::lround(
                          clampf(amount, 0.f, 0.2f) * std::min(bw, bh) / 1.7)));
  std::vector<float> p(static_cast<size_t>(bw) * bh), t1(p.size()), tmp;
  auto one = [&](uint8_t* base, int stride, int pix, int pw, int ph) {
    Taps dx = make_taps(0, pw, pw, bw), dy = make_taps(0, ph, ph, bh);
    resample_to_float(base, stride, pix, dx, dy, 1.f, p.data(), bw, bh, th);
    box_mean(p.data(), t1.data(), bw, bh, r, tmp);
    box_mean(t1.data(), p.data(), bw, bh, r, tmp);
    box_mean(p.data(), t1.data(), bw, bh, r, tmp);
    Taps ux = make_taps(0, bw, bw, pw), uy = make_taps(0, bh, bh, ph);
    std::vector<float> f(static_cast<size_t>(pw) * ph);
    resample_to_float(t1.data(), bw, 1, ux, uy, 1.f, f.data(), pw, ph, th);
    for (int y = 0; y < ph; ++y)
      for (int x = 0; x < pw; ++x)
        base[static_cast<size_t>(y) * stride + static_cast<size_t>(x) * pix] =
            to_u8(f[static_cast<size_t>(y) * pw + x]);
  };
  one(img->y, img->y_stride, 1, w, h);
  int cw = (w + 1) / 2, ch = (h + 1) / 2;
  one(img->u, img->uv_stride, img->uv_pixel_stride, cw, ch);
  one(img->v, img->uv_stride, img->uv_pixel_stride, cw, ch);
  return HBR_OK;
}

namespace {
// dst(x', y') <- src(x, y) for a clockwise rotation, on one plane.
void rotate_plane(const uint8_t* s, int ss, int sp, int sw, int sh, uint8_t* d,
                  int ds, int dp, int rot) {
  int dw = (rot == 90 || rot == 270) ? sh : sw;
  int dh = (rot == 90 || rot == 270) ? sw : sh;
  for (int y = 0; y < dh; ++y) {
    uint8_t* o = d + static_cast<size_t>(y) * ds;
    for (int x = 0; x < dw; ++x) {
      int sx, sy;
      switch (rot) {
        case 90: sx = y; sy = sh - 1 - x; break;
        case 180: sx = sw - 1 - x; sy = sh - 1 - y; break;
        case 270: sx = sw - 1 - y; sy = x; break;
        default: sx = x; sy = y; break;
      }
      o[static_cast<size_t>(x) * dp] =
          s[static_cast<size_t>(sy) * ss + static_cast<size_t>(sx) * sp];
    }
  }
}
}  // namespace

int hbr_rotate_yuv(const hbr_yuv* src, int sw, int sh, hbr_yuv* dst,
                   int rot_cw) {
  if (!src || !dst || sw < 1 || sh < 1) return HBR_ERR_ARG;
  int rot = ((rot_cw % 360) + 360) % 360;
  if (rot % 90) return HBR_ERR_ARG;
  rotate_plane(src->y, src->y_stride, 1, sw, sh, dst->y, dst->y_stride, 1, rot);
  int cw = (sw + 1) / 2, ch = (sh + 1) / 2;
  rotate_plane(src->u, src->uv_stride, src->uv_pixel_stride, cw, ch, dst->u,
               dst->uv_stride, dst->uv_pixel_stride, rot);
  rotate_plane(src->v, src->uv_stride, src->uv_pixel_stride, cw, ch, dst->v,
               dst->uv_stride, dst->uv_pixel_stride, rot);
  return HBR_OK;
}

int hbr_yuv_to_rgba(const hbr_yuv* src, int w, int h, uint8_t* rgba,
                    int stride, hbr_matrix m, int full_range) {
  if (!src || !rgba || w < 1 || h < 1) return HBR_ERR_ARG;
  Coeffs c = coeffs(m);
  float kg = 1.f - c.kr - c.kb;
  for (int y = 0; y < h; ++y) {
    uint8_t* o = rgba + static_cast<size_t>(y) * stride;
    for (int x = 0; x < w; ++x) {
      float Y = src->y[static_cast<size_t>(y) * src->y_stride + x];
      size_t co = static_cast<size_t>(y / 2) * src->uv_stride +
                  static_cast<size_t>(x / 2) * src->uv_pixel_stride;
      float U = src->u[co] - 128.f, V = src->v[co] - 128.f;
      float yl, cb, cr;
      if (full_range) {
        yl = Y / 255.f;
        cb = U / 255.f;
        cr = V / 255.f;
      } else {
        yl = (Y - 16.f) / 219.f;
        cb = U / 224.f;
        cr = V / 224.f;
      }
      float r = yl + 2.f * (1.f - c.kr) * cr;
      float b = yl + 2.f * (1.f - c.kb) * cb;
      float g = (yl - c.kr * r - c.kb * b) / kg;
      o[4 * x + 0] = to_u8(r * 255.f);
      o[4 * x + 1] = to_u8(g * 255.f);
      o[4 * x + 2] = to_u8(b * 255.f);
      o[4 * x + 3] = 255;
    }
  }
  return HBR_OK;
}

}  // extern "C"
