package com.holistic.hbr_engine

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** JNI entry points into the portable C core (see core/include/hbr/hbr_core.h). */
object HbrNative {
    init {
        System.loadLibrary("hbr_jni")
    }

    const val MODE_COLOR = 0
    const val MODE_IMAGE = 1
    const val MODE_BLUR = 2

    const val MATRIX_BT601 = 0
    const val MATRIX_BT709 = 1
    const val MATRIX_BT2020 = 2

    @JvmStatic external fun nativeCreate(
        w: Int, h: Int, temporal: Float, low: Float, high: Float, smoothing: Float, clean: Boolean,
    ): Long
    @JvmStatic external fun nativeDestroy(handle: Long)
    @JvmStatic external fun nativeReset(handle: Long)
    @JvmStatic external fun nativeRefine(
        handle: Long, src: ByteBuffer, w: Int, mask: ByteBuffer, mw: Int, mh: Int, rot: Int,
    ): Int

    @JvmStatic external fun nativeComposite(
        handle: Long, mode: Int, src: ByteBuffer, w: Int, h: Int,
        dy: ByteBuffer, dyStride: Int, du: ByteBuffer, dv: ByteBuffer, duvStride: Int, duvPix: Int,
        bg: ByteBuffer?, color: Int, blur: Float,
    ): Int

    @JvmStatic external fun nativeCopyToI420(
        y: ByteBuffer, yRow: Int, yPix: Int, u: ByteBuffer, v: ByteBuffer, uvRow: Int, uvPix: Int,
        bytesPerSample: Int, cropL: Int, cropT: Int, w: Int, h: Int, dst: ByteBuffer,
    ): Int

    @JvmStatic external fun nativeI420ToRgbaScaled(
        src: ByteBuffer, w: Int, h: Int, dst: ByteBuffer, sw: Int, sh: Int, matrix: Int, full: Boolean,
    ): Int

    @JvmStatic external fun nativeI420ToRgba(
        src: ByteBuffer, w: Int, h: Int, dst: ByteBuffer, matrix: Int, full: Boolean,
    ): Int

    @JvmStatic external fun nativeRgbaToI420Fill(
        rgba: ByteBuffer, w: Int, h: Int, stride: Int, dst: ByteBuffer, dw: Int, dh: Int,
        matrix: Int, full: Boolean,
    ): Int

    @JvmStatic external fun nativeRotateI420(src: ByteBuffer, w: Int, h: Int, dst: ByteBuffer, rot: Int): Int
    @JvmStatic external fun nativeScaleI420Fill(
        src: ByteBuffer, sw: Int, sh: Int, dst: ByteBuffer, dw: Int, dh: Int,
    ): Int

    @JvmStatic external fun nativePlaceRect(
        iw: Int, ih: Int, cw: Int, ch: Int, fit: Boolean, scale: Float, panX: Float, panY: Float, out: IntArray,
    )
    @JvmStatic external fun nativeBlit(
        src: ByteBuffer, sw: Int, sh: Int,
        dy: ByteBuffer, dyStride: Int, du: ByteBuffer, dv: ByteBuffer, duvStride: Int, duvPix: Int,
        dw: Int, dh: Int, rx: Int, ry: Int, rw: Int, rh: Int,
    ): Int
    @JvmStatic external fun nativeCrop(
        src: ByteBuffer, sw: Int, sh: Int, rx: Int, ry: Int, rw: Int, rh: Int, dst: ByteBuffer, dw: Int, dh: Int,
    ): Int
    @JvmStatic external fun nativeOverlay(
        dy: ByteBuffer, dyStride: Int, du: ByteBuffer, dv: ByteBuffer, duvStride: Int, duvPix: Int,
        dw: Int, dh: Int, rgba: ByteBuffer, ow: Int, oh: Int, ostride: Int, x: Int, y: Int,
        premul: Boolean, matrix: Int, full: Boolean,
    ): Int
    @JvmStatic external fun nativeFill(dst: ByteBuffer, w: Int, h: Int, yuv: Int): Int
    @JvmStatic external fun nativeBlur(img: ByteBuffer, w: Int, h: Int, amount: Float): Int
    @JvmStatic external fun nativeOutline(
        handle: Long, dy: ByteBuffer, dyStride: Int, du: ByteBuffer, dv: ByteBuffer, duvStride: Int, duvPix: Int,
        w: Int, h: Int, yuv: Int, width: Float, glow: Boolean,
    ): Int
    @JvmStatic external fun nativeTransition(
        a: ByteBuffer, b: ByteBuffer, out: ByteBuffer, w: Int, h: Int, rotation: Int, type: Int, t: Float,
    ): Int
    @JvmStatic external fun nativeZoom(src: ByteBuffer, dst: ByteBuffer, w: Int, h: Int, scale: Float): Int

    fun placeRect(iw: Int, ih: Int, cw: Int, ch: Int, fit: Boolean, scale: Float = 1f, panX: Float = 0f, panY: Float = 0f): Rect4 {
        val o = IntArray(4)
        nativePlaceRect(iw, ih, cw, ch, fit, scale, panX, panY, o)
        return Rect4(o[0], o[1], o[2], o[3])
    }

    /** Draws tight I420 [src] into [rect] of tight I420 [dst]. */
    fun blit(src: I420Frame, dst: I420Frame, rect: Rect4) {
        check(nativeBlit(src.buffer, src.width, src.height, dst.y, dst.width, dst.u, dst.v, dst.chromaWidth, 1,
            dst.width, dst.height, rect.x, rect.y, rect.w, rect.h) == 0) { "blit failed" }
    }

    @JvmStatic external fun nativeRgbToYuv(r: Int, g: Int, b: Int, matrix: Int, full: Boolean): Int

    fun i420Size(w: Int, h: Int): Int = w * h + 2 * ((w + 1) / 2) * ((h + 1) / 2)

    fun allocI420(w: Int, h: Int): ByteBuffer =
        ByteBuffer.allocateDirect(i420Size(w, h)).order(ByteOrder.nativeOrder())
}

/** Integer rectangle (may extend past the canvas). */
data class Rect4(val x: Int, val y: Int, val w: Int, val h: Int)

/** A tight I420 frame in a direct buffer, with plane views for compositing into it. */
class I420Frame(val width: Int, val height: Int) {
    val buffer: ByteBuffer = HbrNative.allocI420(width, height)
    val chromaWidth = (width + 1) / 2
    private val chromaSize = chromaWidth * ((height + 1) / 2)

    val y: ByteBuffer get() = slice(0, width * height)
    val u: ByteBuffer get() = slice(width * height, chromaSize)
    val v: ByteBuffer get() = slice(width * height + chromaSize, chromaSize)

    private fun slice(offset: Int, len: Int): ByteBuffer {
        val d = buffer.duplicate()
        d.clear()
        d.position(offset)
        d.limit(offset + len)
        return d.slice()
    }
}

/** Matte engine instance; one per export or preview. */
class MatteEngine(
    val width: Int,
    val height: Int,
    temporal: Float,
    edgeSoftness: Float,
    edgeSmoothing: Float = 0.8f,
    cleanEdges: Boolean = true,
) : AutoCloseable {
    private var handle: Long

    init {
        // edgeSoftness 0 -> crisp (0.3..0.7 remapped to 0..1), 1 -> soft.
        val low = 0.3f * (1f - edgeSoftness.coerceIn(0f, 1f))
        handle = HbrNative.nativeCreate(width, height, temporal, low, 1f - low, edgeSmoothing, cleanEdges)
        require(handle != 0L) { "Could not create matte engine for ${width}x$height" }
    }

    fun refine(frame: I420Frame, mask: ByteBuffer, mw: Int, mh: Int, rotation: Int) {
        check(HbrNative.nativeRefine(handle, frame.buffer, width, mask, mw, mh, rotation) == 0) {
            "matte refine failed"
        }
    }

    fun composite(
        src: I420Frame, dy: ByteBuffer, dyStride: Int, du: ByteBuffer, dv: ByteBuffer,
        duvStride: Int, duvPix: Int, bg: BackgroundFrame,
    ) {
        val rc = HbrNative.nativeComposite(
            handle, bg.mode, src.buffer, width, height, dy, dyStride, du, dv, duvStride, duvPix,
            bg.image?.buffer, bg.yuvColor, bg.blur,
        )
        check(rc == 0) { "composite failed ($rc)" }
    }

    /** Draws [o] around the person (planes of this engine's size). */
    fun outline(
        o: OutlineSpec, dy: ByteBuffer, dyStride: Int, du: ByteBuffer, dv: ByteBuffer, duvStride: Int, duvPix: Int,
    ) {
        val rc = HbrNative.nativeOutline(handle, dy, dyStride, du, dv, duvStride, duvPix, width, height, o.yuv, o.width, o.glow)
        check(rc == 0) { "outline failed ($rc)" }
    }

    fun compositeInto(src: I420Frame, dst: I420Frame, bg: BackgroundFrame) =
        composite(src, dst.y, dst.width, dst.u, dst.v, dst.chromaWidth, 1, bg)

    override fun close() {
        if (handle != 0L) HbrNative.nativeDestroy(handle)
        handle = 0L
    }
}

/** A line (or soft glow) around the person; [width] is a fraction of the short side. */
class OutlineSpec(val yuv: Int, val width: Float, val glow: Boolean) {
    companion object {
        /** From settings["outline"] = {argb, width, glow}; null when off. */
        fun from(settings: Map<*, *>, matrix: Int, full: Boolean): OutlineSpec? {
            val o = settings["outline"] as? Map<*, *> ?: return null
            val argb = (o["argb"] as? Number)?.toLong()?.toInt() ?: return null
            val width = ((o["width"] as? Number)?.toFloat() ?: 0.012f).coerceIn(0.002f, 0.05f)
            return OutlineSpec(
                HbrNative.nativeRgbToYuv((argb shr 16) and 0xff, (argb shr 8) and 0xff, argb and 0xff, matrix, full),
                width, o["glow"] as? Boolean ?: false,
            )
        }
    }
}
