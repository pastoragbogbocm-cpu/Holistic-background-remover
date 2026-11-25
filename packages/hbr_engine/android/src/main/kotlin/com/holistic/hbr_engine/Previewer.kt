package com.holistic.hbr_engine

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import java.io.ByteArrayOutputStream

/** Renders a single processed frame for the editor preview. */
class Previewer(private val context: Context) : AutoCloseable {
    private var segmenter: Segmenter? = null

    fun render(path: String, timeMs: Long, background: Map<*, *>, settings: Map<*, *>, maxSize: Int): ByteArray {
        val frameBmp = grabFrame(path, timeMs, maxSize)
        // even dimensions for 4:2:0
        val w = frameBmp.width and 1.inv()
        val h = frameBmp.height and 1.inv()
        val bmp = if (w != frameBmp.width || h != frameBmp.height) {
            Bitmap.createBitmap(frameBmp, 0, 0, w, h)
        } else frameBmp

        val matrix = HbrNative.MATRIX_BT709
        val src = I420Frame(w, h)
        val rgba = BackgroundSource.bitmapToRgba(bmp)
        HbrNative.nativeRgbaToI420Fill(rgba, w, h, bmp.rowBytes, src.buffer, w, h, matrix, true)

        val seg = segmenter ?: Segmenter(context, landscape = w > h, video = false).also { segmenter = it }
        val mask = seg.segmentUpright(bmp)
        val softness = (settings["edgeSoftness"] as? Number)?.toFloat() ?: 0.5f
        val smoothing = (settings["edgeSmoothing"] as? Number)?.toFloat() ?: 0.8f
        val clean = settings["cleanEdges"] as? Boolean ?: true
        val layout = Layout.from(settings, w, h, 0)
        val cw = layout.canvasW
        val ch = layout.canvasH
        val out = I420Frame(cw, ch)
        MatteEngine(w, h, 0f, softness, smoothing, clean).use { engine ->
            engine.refine(src, mask.buffer, mask.width, mask.height, 0)
            BackgroundSource.create(background, cw, ch, 0, matrix, true, previewTimeMs = timeMs).use { bg ->
                Compositor(engine, layout, matrix, true).composeInto(src, out, bg.next())
            }
            CaptionRenderer.from(settings, cw, ch, 0, matrix, true)?.drawInto(timeMs, out)
        }
        val outRgba = java.nio.ByteBuffer.allocateDirect(cw * ch * 4)
        HbrNative.nativeI420ToRgba(out.buffer, cw, ch, outRgba, matrix, true)
        outRgba.rewind()
        val result = Bitmap.createBitmap(cw, ch, Bitmap.Config.ARGB_8888)
        result.copyPixelsFromBuffer(outRgba)
        val bytes = ByteArrayOutputStream()
        result.compress(Bitmap.CompressFormat.JPEG, 92, bytes)
        result.recycle()
        return bytes.toByteArray()
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
    }
}
