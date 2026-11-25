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

    @JvmStatic external fun nativeCreate(w: Int, h: Int, temporal: Float, low: Float, high: Float): Long
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

    @JvmStatic external fun nativeRgbToYuv(r: Int, g: Int, b: Int, matrix: Int, full: Boolean): Int

    fun i420Size(w: Int, h: Int): Int = w * h + 2 * ((w + 1) / 2) * ((h + 1) / 2)

    fun allocI420(w: Int, h: Int): ByteBuffer =
        ByteBuffer.allocateDirect(i420Size(w, h)).order(ByteOrder.nativeOrder())
}

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
) : AutoCloseable {
    private var handle: Long

    init {
        // edgeSoftness 0 -> crisp (0.3..0.7 remapped to 0..1), 1 -> soft.
        val low = 0.3f * (1f - edgeSoftness.coerceIn(0f, 1f))
        handle = HbrNative.nativeCreate(width, height, temporal, low, 1f - low)
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

    fun compositeInto(src: I420Frame, dst: I420Frame, bg: BackgroundFrame) =
        composite(src, dst.y, dst.width, dst.u, dst.v, dst.chromaWidth, 1, bg)

    override fun close() {
        if (handle != 0L) HbrNative.nativeDestroy(handle)
        handle = 0L
    }
}
