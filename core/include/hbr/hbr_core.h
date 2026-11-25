/*
 * HBR core: portable matte refinement + YUV compositing engine.
 *
 * Shared by the iOS and Android apps today, and by desktop/web (WASM) later.
 * Pure C ABI so Swift, Kotlin/JNI, Dart FFI and Emscripten can all call it.
 *
 * Pipeline per frame:
 *   1. hbr_refine_*()  takes the full-resolution luma plane plus a low-res
 *      person-probability mask from any segmentation model, and produces a
 *      full-resolution alpha matte:
 *        - mask resampled into storage orientation (handles rotated video)
 *        - motion-adaptive temporal smoothing (kills flicker, avoids ghosting)
 *        - fast guided filter using the luma as guide (edges snap to hair,
 *          fingers and clothing at full resolution)
 *   2. hbr_composite_*() blends the source frame over a background directly
 *      in Y'CbCr, so the person pixels are never color-converted and keep
 *      the original quality bit-for-bit where alpha == 255.
 *
 * Frames are 8-bit 4:2:0 (NV12, NV21 or I420 via the pixel stride fields).
 */
#ifndef HBR_CORE_H
#define HBR_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define HBR_OK 0
#define HBR_ERR_ARG -1
#define HBR_ERR_STATE -2

typedef enum {
  HBR_MATRIX_BT601 = 0,
  HBR_MATRIX_BT709 = 1,
  HBR_MATRIX_BT2020 = 2
} hbr_matrix;

typedef struct {
  int width;               /* luma width of the stored (unrotated) frame   */
  int height;              /* luma height of the stored (unrotated) frame  */
  float temporal_strength; /* 0 = off, 1 = strongest. Default 0.6           */
  float edge_radius;       /* guided filter radius as a fraction of the
                              short side. Default 0.012                     */
  float edge_eps;          /* guided filter regularisation. Default 0.0008  */
  float matte_low;         /* alpha remap: values <= low become 0. 0.12     */
  float matte_high;        /* alpha remap: values >= high become 1. 0.88    */
  int threads;             /* 0 = auto                                      */
  int decontaminate;       /* 1 = remove the old background's colour from
                              semi-transparent edge pixels (hair, motion
                              blur) so no fringe/halo shows. Default 1     */
  float edge_smoothing;    /* 0..1: removes stair-steps and shimmer from
                              the matte outline. Default 0.8               */
} hbr_config;

/* Planar or semi-planar 4:2:0 image. For NV12 set u = base of UV plane,
 * v = u + 1, uv_pixel_stride = 2. For I420 set uv_pixel_stride = 1. */
typedef struct {
  uint8_t* y;
  int y_stride;
  uint8_t* u;
  uint8_t* v;
  int uv_stride;
  int uv_pixel_stride;
} hbr_yuv;

typedef struct hbr_engine hbr_engine;

void hbr_default_config(hbr_config* cfg, int width, int height);

hbr_engine* hbr_create(const hbr_config* cfg);
void hbr_destroy(hbr_engine* e);

/* Forget temporal history (call after a seek or a hard cut). */
void hbr_reset(hbr_engine* e);

/* mask_rotation: clockwise rotation in degrees (0/90/180/270) that turns the
 * stored frame into the orientation the mask was computed in (i.e. the
 * video's display rotation if segmentation ran on the upright image). */
int hbr_refine_u8(hbr_engine* e, const uint8_t* y, int y_stride,
                  const uint8_t* mask, int mask_w, int mask_h, int mask_stride,
                  int mask_rotation);
int hbr_refine_f32(hbr_engine* e, const uint8_t* y, int y_stride,
                   const float* mask, int mask_w, int mask_h,
                   int mask_stride_floats, int mask_rotation);

/* Full-resolution alpha of the last refined frame (0..255). */
const uint8_t* hbr_alpha(const hbr_engine* e, int* stride);

/* src and dst may be the same image (in-place). */
int hbr_composite_color(hbr_engine* e, const hbr_yuv* src, hbr_yuv* dst,
                        uint8_t y, uint8_t u, uint8_t v);
int hbr_composite_image(hbr_engine* e, const hbr_yuv* src, const hbr_yuv* bg,
                        hbr_yuv* dst);
/* blur_amount: blur radius as a fraction of the short side (e.g. 0.02).
 * Only background pixels contribute to the blur, so the person does not
 * smear a halo into it. */
int hbr_composite_blur(hbr_engine* e, const hbr_yuv* src, hbr_yuv* dst,
                       float blur_amount);

/* ---- helpers for preparing backgrounds and previews ---- */

void hbr_rgb_to_yuv(uint8_t r, uint8_t g, uint8_t b, hbr_matrix m,
                    int full_range, uint8_t* y, uint8_t* u, uint8_t* v);

/* Converts an RGBA image to 4:2:0, scaling with aspect-fill (center crop)
 * into dst of size dw x dh. */
int hbr_rgba_to_yuv_fill(const uint8_t* rgba, int w, int h, int stride,
                         hbr_yuv* dst, int dw, int dh, hbr_matrix m,
                         int full_range);

/* Scales a 4:2:0 image with aspect-fill into dst (dw x dh). Used for video
 * backgrounds whose size differs from the main video. */
int hbr_scale_yuv_fill(const hbr_yuv* src, int sw, int sh, hbr_yuv* dst,
                       int dw, int dh);

/* Rotates a 4:2:0 image clockwise by 0/90/180/270 degrees. For 90/270 the
 * destination is sh x sw. src and dst must not overlap. */
int hbr_rotate_yuv(const hbr_yuv* src, int sw, int sh, hbr_yuv* dst,
                   int rot_cw);

/* 4:2:0 -> RGBA (for previews/thumbnails). */
int hbr_yuv_to_rgba(const hbr_yuv* src, int w, int h, uint8_t* rgba,
                    int stride, hbr_matrix m, int full_range);

#ifdef __cplusplus
}
#endif

#endif /* HBR_CORE_H */
