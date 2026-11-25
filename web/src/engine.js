// Thin JS wrapper over the shared C++ engine compiled to WebAssembly.
import createHbr from './hbr_core.js';

export const MATRIX = { bt601: 0, bt709: 1, bt2020: 2 };

export function matrixOf(colorSpace) {
  const m = colorSpace?.matrix;
  if (m === 'smpte170m' || m === 'bt470bg') return MATRIX.bt601;
  if (m === 'bt2020-ncl') return MATRIX.bt2020;
  return MATRIX.bt709;
}

export const i420Size = (w, h) => w * h + 2 * ((w + 1) >> 1) * ((h + 1) >> 1);

let modulePromise;
export function loadCore() {
  modulePromise ??= createHbr();
  return modulePromise;
}

/** Owns WASM buffers for one frame size plus one engine instance. */
export class Engine {
  constructor(M, w, h, { temporal = 0.6, softness = 0.5, smoothing = 0.8, clean = true } = {}) {
    this.M = M;
    this.w = w;
    this.h = h;
    this.size = i420Size(w, h);
    const low = 0.3 * (1 - Math.min(Math.max(softness, 0), 1));
    this.e = M._hbrw_create(w, h, temporal, low, 1 - low, smoothing, clean ? 1 : 0);
    if (!this.e) throw new Error(`Could not create engine for ${w}x${h}`);
    this.src = M._hbrw_alloc(this.size);
    this.dst = M._hbrw_alloc(this.size);
    this.bg = M._hbrw_alloc(this.size);
    this.tmp = M._hbrw_alloc(Math.max(this.size, w * h * 4));
    this.maskPtr = 0;
    this.maskCap = 0;
    this.rgbaPtr = 0;
    this.rgbaCap = 0;
  }

  get heap() {
    return this.M.HEAPU8; // re-read: memory growth replaces the buffer
  }

  view(ptr, len) {
    return this.heap.subarray(ptr, ptr + len);
  }

  ensureMask(n) {
    if (n > this.maskCap) {
      if (this.maskPtr) this.M._hbrw_free(this.maskPtr);
      this.maskPtr = this.M._hbrw_alloc(n * 4);
      this.maskCap = n;
    }
    return this.maskPtr;
  }

  ensureRgba(n) {
    if (n > this.rgbaCap) {
      if (this.rgbaPtr) this.M._hbrw_free(this.rgbaPtr);
      this.rgbaPtr = this.M._hbrw_alloc(n);
      this.rgbaCap = n;
    }
    return this.rgbaPtr;
  }

  /** Small RGBA copy of the current source frame for the segmentation model. */
  smallRgba(sw, sh, matrix, full) {
    const p = this.ensureRgba(sw * sh * 4);
    this.M._hbrw_i420_to_rgba_scaled(this.src, this.w, this.h, p, sw, sh, matrix, full ? 1 : 0);
    return new ImageData(new Uint8ClampedArray(this.view(p, sw * sh * 4)), sw, sh);
  }

  refine(maskFloats, mw, mh, rotation) {
    const p = this.ensureMask(mw * mh);
    this.M.HEAPF32.set(maskFloats, p >> 2);
    const rc = this.M._hbrw_refine(this.e, this.src, this.w, p, mw, mh, rotation);
    if (rc) throw new Error('matte refine failed');
  }

  /** bg: {mode:0,color} | {mode:1} (this.bg filled) | {mode:2,blur} */
  composite(bg) {
    const rc = this.M._hbrw_composite(this.e, bg.mode, this.src, this.dst, this.w, this.h, this.bg,
      bg.color ?? 0, bg.blur ?? 0.03);
    if (rc) throw new Error('composite failed');
  }

  /** RGBA (any size, upright) -> aspect-filled I420 written to `ptr` (dw x dh). */
  rgbaToI420(imageData, ptr, dw, dh, matrix, full) {
    const n = imageData.width * imageData.height * 4;
    const p = this.ensureRgba(n);
    this.heap.set(imageData.data, p);
    this.M._hbrw_rgba_to_i420_fill(p, imageData.width, imageData.height, ptr, dw, dh, matrix, full ? 1 : 0);
  }

  /** Fills this.bg from an upright picture, rotated into stored orientation. */
  setBackgroundPicture(imageData, rotation, matrix, full) {
    if (!rotation) return this.rgbaToI420(imageData, this.bg, this.w, this.h, matrix, full);
    const swap = rotation === 90 || rotation === 270;
    const dw = swap ? this.h : this.w;
    const dh = swap ? this.w : this.h;
    this.rgbaToI420(imageData, this.tmp, dw, dh, matrix, full);
    this.M._hbrw_rotate_i420(this.tmp, dw, dh, this.bg, (360 - rotation) % 360);
  }

  yuvColor(argb, matrix, full) {
    return this.M._hbrw_rgb_to_yuv((argb >> 16) & 255, (argb >> 8) & 255, argb & 255, matrix, full ? 1 : 0);
  }

  outputRgba(matrix, full) {
    const n = this.w * this.h * 4;
    const p = this.ensureRgba(n);
    this.M._hbrw_i420_to_rgba(this.dst, this.w, this.h, p, matrix, full ? 1 : 0);
    return new ImageData(new Uint8ClampedArray(this.view(p, n)), this.w, this.h);
  }

  destroy() {
    const M = this.M;
    M._hbrw_destroy(this.e);
    for (const p of [this.src, this.dst, this.bg, this.tmp, this.maskPtr, this.rgbaPtr]) if (p) M._hbrw_free(p);
  }
}
