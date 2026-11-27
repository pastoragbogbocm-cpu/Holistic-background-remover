package com.holistic.hbr_engine

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Renders a single processed frame for the editor preview.
 *
 * The decoded frame and the person mask are kept between calls, so changing
 * the background, its size/position, the frame shape or the captions only
 * re-composites (fast) instead of decoding and segmenting again. A decoded
 * background picture is kept too.
 */
class Previewer(private val context: Context) : AutoCloseable {
    private var segmenter: Segmenter? = null

    private class Source(val key: String, val w: Int, val h: Int, val yuv: ByteBuffer, val mask: ByteBuffer, val mw: Int, val mh: Int)
    private var source: Source? = null
    private var bgKey: String? = null
    private var bgSource: BackgroundSource? = null

    fun render(path: String, timeMs: Long, background: Map<*, *>, settings: Map<*, *>, maxSize: Int): ByteArray {
        val src = sourceFor(path, timeMs, maxSize, settings)
        val w = src.w
        val h = src.h
        val matrix = HbrNative.MATRIX_BT709
        val frame = I420Frame(w, h)
        frame.buffer.put(src.yuv.duplicate().also { it.rewind() }).rewind()
        val mask = src.mask.duplicate().order(ByteOrder.nativeOrder()).also { it.rewind() }

        val softness = (settings["edgeSoftness"] as? Number)?.toFloat() ?: 0.2f
        val smoothing = (settings["edgeSmoothing"] as? Number)?.toFloat() ?: 0.8f
        val clean = settings["cleanEdges"] as? Boolean ?: true
        val layout = Layout.from(settings, w, h, 0)
        val cw = layout.canvasW
        val ch = layout.canvasH
        val out = I420Frame(cw, ch)
        MatteEngine(w, h, 0f, softness, smoothing, clean).use { engine ->
            engine.refine(frame, mask, src.mw, src.mh, 0)
            Compositor(engine, layout, matrix, true, OutlineSpec.from(settings, matrix, true)).composeInto(frame, out, backgroundFor(background, cw, ch, timeMs, matrix).next())
            CaptionRenderer.from(settings, cw, ch, 0, matrix, true)?.drawInto(timeMs, out)
        }
        val outRgba = ByteBuffer.allocateDirect(cw * ch * 4)
        HbrNative.nativeI420ToRgba(out.buffer, cw, ch, outRgba, matrix, true)
        outRgba.rewind()
        val result = Bitmap.createBitmap(cw, ch, Bitmap.Config.ARGB_8888)
        result.copyPixelsFromBuffer(outRgba)
        val bytes = ByteArrayOutputStream()
        result.compress(Bitmap.CompressFormat.JPEG, 90, bytes)
        result.recycle()
        return bytes.toByteArray()
    }

    /** Decoded frame + person mask for this video time, reused while only other settings change. */
    private fun sourceFor(path: String, timeMs: Long, maxSize: Int, settings: Map<*, *>): Source {
        val hq = settings["highQuality"] ?: settings["highQualitySegmentation"]
        val key = "$path|$timeMs|$maxSize|$hq"
        source?.takeIf { it.key == key }?.let { return it }
        val frameBmp = grabFrame(path, timeMs, maxSize)
        // even dimensions for 4:2:0
        val w = frameBmp.width and 1.inv()
        val h = frameBmp.height and 1.inv()
        val bmp = if (w != frameBmp.width || h != frameBmp.height) {
            Bitmap.createBitmap(frameBmp, 0, 0, w, h)
        } else frameBmp
        val yuv = HbrNative.allocI420(w, h)
        val rgba = BackgroundSource.bitmapToRgba(bmp)
        HbrNative.nativeRgbaToI420Fill(rgba, w, h, bmp.rowBytes, yuv, w, h, HbrNative.MATRIX_BT709, true)
        val seg = segmenter ?: Segmenter(context, landscape = w > h, video = false).also { segmenter = it }
        val m = seg.segmentUpright(bmp)
        val maskCopy = ByteBuffer.allocateDirect(m.buffer.capacity()).order(ByteOrder.nativeOrder())
        maskCopy.put(m.buffer.duplicate().also { it.rewind() }).rewind()
        if (bmp !== frameBmp) bmp.recycle()
        frameBmp.recycle()
        return Source(key, w, h, yuv, maskCopy, m.width, m.height).also { source = it }
    }

    /** The background for this canvas, decoded once and reused until it changes. */
    private fun backgroundFor(spec: Map<*, *>, cw: Int, ch: Int, timeMs: Long, matrix: Int): BackgroundSource {
        val video = spec["type"] == "video"
        val key = "$spec|$cw|$ch" + if (video) "|$timeMs" else ""
        bgSource?.takeIf { bgKey == key }?.let { return it }
        bgSource?.close()
        bgSource = null
        val bg = BackgroundSource.create(spec, cw, ch, 0, matrix, true, previewTimeMs = timeMs)
        bgSource = bg
        bgKey = key
        return bg
    }

    /** Upright frame, longest side <= maxSize. */
    private fun grabFrame(path: String, timeMs: Long, maxSize: Int): Bitmap {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(path)
            val us = timeMs * 1000
            val raw = if (Build.VERSION.SDK_INT >= 27) {
                r.getScaledFrameAtTime(us, MediaMetadataRetriever.OPTION_CLOSEST, maxSize, maxSize)
            } else {
                r.getFrameAtTime(us, MediaMetadataRetriever.OPTION_CLOSEST)
            } ?: throw IllegalStateException("Could not read a frame at ${timeMs}ms")
            var bmp = raw.copy(Bitmap.Config.ARGB_8888, false)
            val longest = maxOf(bmp.width, bmp.height)
            if (longest > maxSize) {
                val s = maxSize.toFloat() / longest
                bmp = Bitmap.createScaledBitmap(bmp, (bmp.width * s).toInt(), (bmp.height * s).toInt(), true)
            }
            return bmp
        } finally {
            r.release()
        }
    }

    override fun close() {
        segmenter?.close()
        segmenter = null
        bgSource?.close()
        bgSource = null
        source = null
    }
}
