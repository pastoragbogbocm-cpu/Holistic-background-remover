package com.holistic.hbr_engine

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.util.Log
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.framework.image.ByteBufferExtractor
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.imagesegmenter.ImageSegmenter
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Person probability mask, upright (display orientation), float32 0..1. */
class PersonMask(val buffer: ByteBuffer, val width: Int, val height: Int) {
    /** Fraction of mask pixels that are confidently the person (>= 0.5). */
    fun coverage(): Float {
        val f = buffer.duplicate().order(ByteOrder.nativeOrder()).asFloatBuffer()
        val n = width * height
        if (n == 0) return 0f
        var hit = 0
        // Sampling every 4th pixel is plenty for a 256 px mask.
        var i = 0
        var seen = 0
        while (i < n) {
            if (f.get(i) >= 0.5f) hit++
            seen++
            i += 4
        }
        return hit.toFloat() / seen
    }
}

/**
 * On-device person segmentation with MediaPipe's selfie segmenter. The
 * models ship inside the app, so this works fully offline.
 *
 * Segmentation runs on a small upright copy of the frame (the model input is
 * 256 px anyway); the core then rebuilds a full-resolution matte from it
 * using the original luma as guide, so this costs no output quality.
 */
class Segmenter(
    context: Context,
    landscape: Boolean,
    private val video: Boolean,
) : AutoCloseable {
    private val segmenter: ImageSegmenter = create(context, landscape, video)
    private var lastTsMs = -1L
    private var rgba: ByteBuffer? = null
    private var maskBuf: ByteBuffer? = null

    /**
     * Segments a stored-orientation I420 frame. [rotation] is the clockwise
     * display rotation; the returned mask is upright.
     */
    fun segment(frame: I420Frame, rotation: Int, matrix: Int, fullRange: Boolean, ptsUs: Long): PersonMask {
        // ~256 px on the short side keeps the aspect ratio; MediaPipe resizes
        // to the exact tensor size itself.
        val scale = 256f / minOf(frame.width, frame.height)
        val sw = maxOf(2, (frame.width * scale).toInt() and 1.inv())
        val sh = maxOf(2, (frame.height * scale).toInt() and 1.inv())
        val need = sw * sh * 4
        val buf = rgba?.takeIf { it.capacity() >= need }
            ?: ByteBuffer.allocateDirect(need).order(ByteOrder.nativeOrder()).also { rgba = it }
        HbrNative.nativeI420ToRgbaScaled(frame.buffer, frame.width, frame.height, buf, sw, sh, matrix, fullRange)
        buf.rewind()
        var bmp = Bitmap.createBitmap(sw, sh, Bitmap.Config.ARGB_8888)
        bmp.copyPixelsFromBuffer(buf)
        if (rotation != 0) {
            val m = Matrix().apply { postRotate(rotation.toFloat()) }
            val rotated = Bitmap.createBitmap(bmp, 0, 0, sw, sh, m, true)
            bmp.recycle()
            bmp = rotated
        }
        return segmentUpright(bmp, ptsUs).also { bmp.recycle() }
    }

    /** Segments an already-upright bitmap. */
    fun segmentUpright(bitmap: Bitmap, ptsUs: Long = 0): PersonMask {
        val mpImage = BitmapImageBuilder(bitmap).build()
        val result = if (video) {
            var ts = ptsUs / 1000
            if (ts <= lastTsMs) ts = lastTsMs + 1 // MediaPipe needs strictly increasing timestamps
            lastTsMs = ts
            segmenter.segmentForVideo(mpImage, ts)
        } else {
            segmenter.segment(mpImage)
        }
        val masks = result.confidenceMasks().orElseThrow { IllegalStateException("No confidence mask") }
        // Single-output models give one "person" mask; two-class models list
        // background first. Either way the person is the last mask.
        val m = masks.last()
        val src = ByteBufferExtractor.extract(m)
        src.rewind()
        val need = m.width * m.height * 4
        val dst = maskBuf?.takeIf { it.capacity() >= need }
            ?: ByteBuffer.allocateDirect(need).order(ByteOrder.nativeOrder()).also { maskBuf = it }
        dst.clear()
        src.limit(minOf(src.capacity(), need))
        dst.put(src)
        dst.rewind()
        return PersonMask(dst, m.width, m.height)
    }

    override fun close() = segmenter.close()

    private companion object {
        fun create(context: Context, landscape: Boolean, video: Boolean): ImageSegmenter {
            val model = if (landscape) "selfie_segmenter_landscape.tflite" else "selfie_segmenter.tflite"
            val mode = if (video) RunningMode.VIDEO else RunningMode.IMAGE
            // CPU (XNNPACK) first: the model is tiny (256 px), so it is fast,
            // and it gives identical results on every phone. Some mobile GPU
            // drivers return empty masks for this model.
            for (delegate in listOf(Delegate.CPU, Delegate.GPU)) {
                try {
                    val base = BaseOptions.builder().setModelAssetPath(model).setDelegate(delegate).build()
                    val opts = ImageSegmenter.ImageSegmenterOptions.builder()
                        .setBaseOptions(base)
                        .setRunningMode(mode)
                        .setOutputConfidenceMasks(true)
                        .setOutputCategoryMask(false)
                        .build()
                    return ImageSegmenter.createFromOptions(context, opts)
                } catch (e: Exception) {
                    Log.w("HbrEngine", "Segmenter with $delegate failed, trying next", e)
                }
            }
            throw IllegalStateException("Could not start person segmentation")
        }
    }
}
