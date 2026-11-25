// JNI bridge between Kotlin (HbrNative.kt) and the portable C core.
// All image buffers are direct ByteBuffers so no pixel data is copied
// across the JNI boundary.
#include <jni.h>

#include <algorithm>
#include <cstring>
#include <vector>

#include "hbr/hbr_core.h"

namespace {

uint8_t* addr(JNIEnv* env, jobject buf) {
  return buf ? static_cast<uint8_t*>(env->GetDirectBufferAddress(buf))
             : nullptr;
}

// Tight I420 view over a w x h buffer.
hbr_yuv i420(uint8_t* base, int w, int h) {
  int cw = (w + 1) / 2, ch = (h + 1) / 2;
  uint8_t* u = base + static_cast<size_t>(w) * h;
  return hbr_yuv{base, w, u, u + static_cast<size_t>(cw) * ch, cw, 1};
}

hbr_engine* eng(jlong h) { return reinterpret_cast<hbr_engine*>(h); }

}  // namespace

#define JNI_FN(ret, name) \
  JNIEXPORT ret JNICALL Java_com_holistic_hbr_1engine_HbrNative_##name

extern "C" {

JNI_FN(jlong, nativeCreate)(JNIEnv*, jclass, jint w, jint h, jfloat temporal,
                           jfloat low, jfloat high, jfloat smoothing,
                           jboolean clean) {
  hbr_config c;
  hbr_default_config(&c, w, h);
  c.temporal_strength = temporal;
  c.edge_smoothing = smoothing;
  c.decontaminate = clean ? 1 : 0;
  c.matte_low = low;
  c.matte_high = high;
  return reinterpret_cast<jlong>(hbr_create(&c));
}

JNI_FN(void, nativeDestroy)(JNIEnv*, jclass, jlong h) { hbr_destroy(eng(h)); }

JNI_FN(void, nativeReset)(JNIEnv*, jclass, jlong h) { hbr_reset(eng(h)); }

// src: tight I420 frame. mask: direct buffer of float32 (native order).
JNI_FN(jint, nativeRefine)(JNIEnv* env, jclass, jlong h, jobject src, jint w,
                          jobject mask, jint mw, jint mh, jint rot) {
  (void)w;
  uint8_t* y = addr(env, src);
  auto* m = reinterpret_cast<const float*>(addr(env, mask));
  if (!y || !m) return HBR_ERR_ARG;
  return hbr_refine_f32(eng(h), y, w, m, mw, mh, mw, rot);
}

// mode: 0 color, 1 image (bg = tight I420 of frame size), 2 blur.
// dst is given as planes so it can be a MediaCodec input Image directly.
JNI_FN(jint, nativeComposite)(JNIEnv* env, jclass, jlong h, jint mode,
                             jobject src, jint w, jint hgt, jobject dy,
                             jint dyStride, jobject du, jobject dv,
                             jint duvStride, jint duvPix, jobject bg,
                             jint color, jfloat blur) {
  uint8_t* s = addr(env, src);
  if (!s) return HBR_ERR_ARG;
  hbr_yuv sv = i420(s, w, hgt);
  hbr_yuv dvw{addr(env, dy), dyStride, addr(env, du), addr(env, dv), duvStride,
              duvPix};
  if (!dvw.y || !dvw.u || !dvw.v) return HBR_ERR_ARG;
  switch (mode) {
    case 0:
      return hbr_composite_color(eng(h), &sv, &dvw, (color >> 16) & 0xff,
                                 (color >> 8) & 0xff, color & 0xff);
    case 1: {
      uint8_t* b = addr(env, bg);
      if (!b) return HBR_ERR_ARG;
      hbr_yuv bv = i420(b, w, hgt);
      return hbr_composite_image(eng(h), &sv, &bv, &dvw);
    }
    case 2:
      return hbr_composite_blur(eng(h), &sv, &dvw, blur);
    default:
      return HBR_ERR_ARG;
  }
}

// Copies a decoder Image (YUV_420_888 or 10-bit P010) into a tight 8-bit
// I420 buffer. bytesPerSample = 2 for P010: the high byte is taken, which
// is the 8 most significant bits of the 10-bit sample.
JNI_FN(jint, nativeCopyToI420)(JNIEnv* env, jclass, jobject y, jint yRow,
                              jint yPix, jobject u, jobject v, jint uvRow,
                              jint uvPix, jint bytesPerSample, jint cropL,
                              jint cropT, jint w, jint h, jobject dst) {
  uint8_t* sy = addr(env, y);
  uint8_t* su = addr(env, u);
  uint8_t* sv = addr(env, v);
  uint8_t* d = addr(env, dst);
  if (!sy || !su || !sv || !d) return HBR_ERR_ARG;
  const int hi = bytesPerSample == 2 ? 1 : 0;  // little-endian high byte
  hbr_yuv o = i420(d, w, h);
  for (int r = 0; r < h; ++r) {
    const uint8_t* s =
        sy + static_cast<size_t>(r + cropT) * yRow + static_cast<size_t>(cropL) * yPix + hi;
    uint8_t* out = o.y + static_cast<size_t>(r) * w;
    if (yPix == 1) {
      std::memcpy(out, s, w);
    } else {
      for (int x = 0; x < w; ++x) out[x] = s[static_cast<size_t>(x) * yPix];
    }
  }
  const int cw = (w + 1) / 2, ch = (h + 1) / 2;
  const int cl = cropL / 2, ct = cropT / 2;
  for (int r = 0; r < ch; ++r) {
    size_t off = static_cast<size_t>(r + ct) * uvRow + static_cast<size_t>(cl) * uvPix + hi;
    uint8_t* ou = o.u + static_cast<size_t>(r) * cw;
    uint8_t* ov = o.v + static_cast<size_t>(r) * cw;
    for (int x = 0; x < cw; ++x) {
      ou[x] = su[off + static_cast<size_t>(x) * uvPix];
      ov[x] = sv[off + static_cast<size_t>(x) * uvPix];
    }
  }
  return HBR_OK;
}

// Downscales a tight I420 frame to sw x sh RGBA for the segmentation model.
JNI_FN(jint, nativeI420ToRgbaScaled)(JNIEnv* env, jclass, jobject src, jint w,
                                    jint h, jobject dst, jint sw, jint sh,
                                    jint matrix, jboolean full) {
  uint8_t* s = addr(env, src);
  uint8_t* d = addr(env, dst);
  if (!s || !d) return HBR_ERR_ARG;
  hbr_yuv sv = i420(s, w, h);
  std::vector<uint8_t> small(static_cast<size_t>(sw) * sh +
                             2 * static_cast<size_t>((sw + 1) / 2) * ((sh + 1) / 2));
  hbr_yuv smv = i420(small.data(), sw, sh);
  int rc = hbr_scale_yuv_fill(&sv, w, h, &smv, sw, sh);
  if (rc) return rc;
  return hbr_yuv_to_rgba(&smv, sw, sh, d, sw * 4,
                         static_cast<hbr_matrix>(matrix), full ? 1 : 0);
}

JNI_FN(jint, nativeI420ToRgba)(JNIEnv* env, jclass, jobject src, jint w, jint h,
                              jobject dst, jint matrix, jboolean full) {
  uint8_t* s = addr(env, src);
  uint8_t* d = addr(env, dst);
  if (!s || !d) return HBR_ERR_ARG;
  hbr_yuv sv = i420(s, w, h);
  return hbr_yuv_to_rgba(&sv, w, h, d, w * 4, static_cast<hbr_matrix>(matrix),
                         full ? 1 : 0);
}

JNI_FN(jint, nativeRgbaToI420Fill)(JNIEnv* env, jclass, jobject rgba, jint w,
                                  jint h, jint stride, jobject dst, jint dw,
                                  jint dh, jint matrix, jboolean full) {
  uint8_t* s = addr(env, rgba);
  uint8_t* d = addr(env, dst);
  if (!s || !d) return HBR_ERR_ARG;
  hbr_yuv dv = i420(d, dw, dh);
  return hbr_rgba_to_yuv_fill(s, w, h, stride, &dv, dw, dh,
                              static_cast<hbr_matrix>(matrix), full ? 1 : 0);
}

JNI_FN(jint, nativeRotateI420)(JNIEnv* env, jclass, jobject src, jint w, jint h,
                              jobject dst, jint rot) {
  uint8_t* s = addr(env, src);
  uint8_t* d = addr(env, dst);
  if (!s || !d) return HBR_ERR_ARG;
  hbr_yuv sv = i420(s, w, h);
  bool swap = rot == 90 || rot == 270;
  hbr_yuv dv = i420(d, swap ? h : w, swap ? w : h);
  return hbr_rotate_yuv(&sv, w, h, &dv, rot);
}

JNI_FN(jint, nativeScaleI420Fill)(JNIEnv* env, jclass, jobject src, jint sw,
                                 jint sh, jobject dst, jint dw, jint dh) {
  uint8_t* s = addr(env, src);
  uint8_t* d = addr(env, dst);
  if (!s || !d) return HBR_ERR_ARG;
  hbr_yuv sv = i420(s, sw, sh);
  hbr_yuv dv = i420(d, dw, dh);
  return hbr_scale_yuv_fill(&sv, sw, sh, &dv, dw, dh);
}

// ---- layout helpers ----

JNI_FN(void, nativePlaceRect)(JNIEnv* env, jclass, jint iw, jint ih, jint cw,
                             jint ch, jboolean fit, jfloat scale, jfloat px,
                             jfloat py, jintArray out) {
  int r[4];
  hbr_place_rect(iw, ih, cw, ch, fit ? 1 : 0, scale, px, py, &r[0], &r[1],
                 &r[2], &r[3]);
  jint o[4] = {r[0], r[1], r[2], r[3]};
  env->SetIntArrayRegion(out, 0, 4, o);
}

// src: tight I420. dst given as planes (can be a MediaCodec input Image).
JNI_FN(jint, nativeBlit)(JNIEnv* env, jclass, jobject src, jint sw, jint sh,
                        jobject dy, jint dyStride, jobject du, jobject dv,
                        jint duvStride, jint duvPix, jint dw, jint dh, jint rx,
                        jint ry, jint rw, jint rh) {
  uint8_t* s = addr(env, src);
  if (!s) return HBR_ERR_ARG;
  hbr_yuv sv = i420(s, sw, sh);
  hbr_yuv dvw{addr(env, dy), dyStride, addr(env, du), addr(env, dv), duvStride,
              duvPix};
  if (!dvw.y || !dvw.u || !dvw.v) return HBR_ERR_ARG;
  return hbr_blit_yuv(&sv, sw, sh, &dvw, dw, dh, rx, ry, rw, rh);
}

JNI_FN(jint, nativeCrop)(JNIEnv* env, jclass, jobject src, jint sw, jint sh,
                        jint rx, jint ry, jint rw, jint rh, jobject dst,
                        jint dw, jint dh) {
  uint8_t* s = addr(env, src);
  uint8_t* d = addr(env, dst);
  if (!s || !d) return HBR_ERR_ARG;
  hbr_yuv sv = i420(s, sw, sh);
  hbr_yuv dv = i420(d, dw, dh);
  return hbr_crop_yuv(&sv, sw, sh, rx, ry, rw, rh, &dv, dw, dh);
}

// yuv = 0x00YYUUVV
JNI_FN(jint, nativeFill)(JNIEnv* env, jclass, jobject dst, jint w, jint h,
                        jint yuv) {
  uint8_t* d = addr(env, dst);
  if (!d) return HBR_ERR_ARG;
  hbr_yuv dv = i420(d, w, h);
  return hbr_fill_yuv(&dv, w, h, (yuv >> 16) & 0xff, (yuv >> 8) & 0xff,
                      yuv & 0xff);
}

JNI_FN(jint, nativeBlur)(JNIEnv* env, jclass, jobject img, jint w, jint h,
                        jfloat amount) {
  uint8_t* d = addr(env, img);
  if (!d) return HBR_ERR_ARG;
  hbr_yuv dv = i420(d, w, h);
  return hbr_blur_yuv(&dv, w, h, amount);
}

// Alpha-blends an RGBA buffer (premultiplied when premul) onto planes.
JNI_FN(jint, nativeOverlay)(JNIEnv* env, jclass, jobject dy, jint dyStride,
                           jobject du, jobject dv, jint duvStride, jint duvPix,
                           jint dw, jint dh, jobject rgba, jint ow, jint oh,
                           jint ostride, jint x, jint y, jboolean premul,
                           jint matrix, jboolean full) {
  hbr_yuv d{addr(env, dy), dyStride, addr(env, du), addr(env, dv), duvStride, duvPix};
  uint8_t* s = addr(env, rgba);
  if (!d.y || !d.u || !d.v || !s) return HBR_ERR_ARG;
  return hbr_overlay_rgba(&d, dw, dh, s, ow, oh, ostride, x, y, premul ? 1 : 0,
                          static_cast<hbr_matrix>(matrix), full ? 1 : 0);
}

// Returns 0x00YYUUVV.
JNI_FN(jint, nativeRgbToYuv)(JNIEnv*, jclass, jint r, jint g, jint b,
                            jint matrix, jboolean full) {
  uint8_t y, u, v;
  hbr_rgb_to_yuv(static_cast<uint8_t>(r), static_cast<uint8_t>(g),
                 static_cast<uint8_t>(b), static_cast<hbr_matrix>(matrix),
                 full ? 1 : 0, &y, &u, &v);
  return (y << 16) | (u << 8) | v;
}

}  // extern "C"
