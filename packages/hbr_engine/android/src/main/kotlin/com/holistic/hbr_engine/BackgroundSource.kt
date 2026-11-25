package com.holistic.hbr_engine

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.media.MediaMetadataRetriever
import android.os.Build
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** What the compositor needs for one frame. */
class BackgroundFrame(
    val mode: Int,
    val image: I420Frame? = null,
    val yuvColor: Int = 0,
    val blur: Float = 0f,
)

/**
 * Produces the background for each output frame, already converted to the
 * output's stored orientation, size and colour matrix, so compositing is a
 * straight per-pixel blend.
 */
sealed class BackgroundSource : AutoCloseable {
    abstract fun next(): BackgroundFrame
    override fun close() {}

    class Solid(argb: Int, matrix: Int, full: Boolean) : BackgroundSource() {
        private val frame = BackgroundFrame(
            HbrNative.MODE_COLOR,
            yuvColor = HbrNative.nativeRgbToYuv(
                (argb shr 16) and 0xff, (argb shr 8) and 0xff, argb and 0xff, matrix, full,
            ),
        )
        override fun next() = frame
    }

    class Blur(amount: Float) : BackgroundSource() {
        private val frame = BackgroundFrame(HbrNative.MODE_BLUR, blur = amount.coerceIn(0.002f, 0.2f))
        override fun next() = frame
    }

    /** A still image, aspect-filled and rotated into storage orientation once. */
    class Still(bitmap: Bitmap, w: Int, h: Int, rotation: Int, matrix: Int, full: Boolean) : BackgroundSource() {
        private val frame: BackgroundFrame

        init {
            val dispW = if (rotation % 180 == 0) w else h
            val dispH = if (rotation % 180 == 0) h else w
            val upright = I420Frame(dispW, dispH)
            val argb = if (bitmap.config == Bitmap.Config.ARGB_8888) bitmap else bitmap.copy(Bitmap.Config.ARGB_8888, false)
            val rgba = bitmapToRgba(argb)
            HbrNative.nativeRgbaToI420Fill(rgba, argb.width, argb.height, argb.rowBytes, upright.buffer, dispW, dispH, matrix, full)
            val stored = if (rotation == 0) upright else I420Frame(w, h).also {
                // upright -> stored is the inverse of the display rotation
                HbrNative.nativeRotateI420(upright.buffer, dispW, dispH, it.buffer, (360 - rotation) % 360)
            }
            frame = BackgroundFrame(HbrNative.MODE_IMAGE, image = stored)
        }

        override fun next() = frame
    }

    /** A looping video, decoded in step with the main video. */
    class Video(path: String, private val w: Int, private val h: Int, private val rotation: Int) : BackgroundSource() {
        private val decoder = FrameDecoder(path, loop = true)
        private val out = I420Frame(w, h)
        private val frame = BackgroundFrame(HbrNative.MODE_IMAGE, image = out)
        private val turn = ((decoder.meta.rotation - rotation) % 360 + 360) % 360
        private val rotated: I420Frame? = when (turn) {
            0 -> null
            90, 270 -> I420Frame(decoder.height, decoder.width)
            else -> I420Frame(decoder.width, decoder.height)
        }

        override fun next(): BackgroundFrame {
            if (!decoder.next()) return frame // empty/broken file: keep last frame
            var src = decoder.frame
            if (rotated != null) {
                HbrNative.nativeRotateI420(src.buffer, src.width, src.height, rotated.buffer, turn)
                src = rotated
            }
            HbrNative.nativeScaleI420Fill(src.buffer, src.width, src.height, out.buffer, w, h)
            return frame
        }

        override fun close() = decoder.close()
    }

    companion object {
        /**
         * @param spec the Dart `Background.toMap()`.
         * @param previewTimeMs for previews, a video background shows the
         *   frame at this time instead of being decoded sequentially.
         */
        fun create(
            spec: Map<*, *>, w: Int, h: Int, rotation: Int, matrix: Int, full: Boolean,
            previewTimeMs: Long? = null,
        ): BackgroundSource = when (spec["type"]) {
            "color" -> Solid((spec["argb"] as Number).toInt(), matrix, full)
            "blur" -> Blur((spec["amount"] as? Number)?.toFloat() ?: 0.03f)
            "image" -> {
                val bmp = loadBitmap(spec["path"] as String, maxOf(w, h))
                Still(bmp, w, h, rotation, matrix, full).also { bmp.recycle() }
            }
            "video" -> {
                val path = spec["path"] as String
                if (previewTimeMs != null) {
                    Still(videoFrame(path, previewTimeMs), w, h, rotation, matrix, full)
                } else Video(path, w, h, rotation)
            }
            else -> throw IllegalArgumentException("Unknown background ${spec["type"]}")
        }

        /** Decodes an image upright (EXIF applied), roughly at [target] px. */
        fun loadBitmap(path: String, target: Int): Bitmap {
            if (Build.VERSION.SDK_INT >= 28) {
                val src = ImageDecoder.createSource(File(path))
                return ImageDecoder.decodeBitmap(src) { dec, info, _ ->
                    dec.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                    val longest = maxOf(info.size.width, info.size.height)
                    if (longest > target * 2) {
                        val s = target * 2f / longest
                        dec.setTargetSize((info.size.width * s).toInt(), (info.size.height * s).toInt())
                    }
                }.copy(Bitmap.Config.ARGB_8888, false)
            }
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            var sample = 1
            while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= target) sample *= 2
            val opts = BitmapFactory.Options().apply {
                inSampleSize = sample
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
            return BitmapFactory.decodeFile(path, opts) ?: throw IllegalArgumentException("Cannot read image $path")
        }

        /** Upright frame of a video at [timeMs] (looping past the end). */
        fun videoFrame(path: String, timeMs: Long): Bitmap {
            val r = MediaMetadataRetriever()
            try {
                r.setDataSource(path)
                val dur = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
                val t = if (dur > 0) timeMs % dur else 0L
                val bmp = r.getFrameAtTime(t * 1000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                    ?: throw IllegalArgumentException("Cannot read background video")
                return bmp.copy(Bitmap.Config.ARGB_8888, false)
            } finally {
                r.release()
            }
        }

        /** ARGB_8888 bitmap memory is laid out as R,G,B,A bytes, rowBytes per row. */
        fun bitmapToRgba(bitmap: Bitmap): ByteBuffer {
            val buf = ByteBuffer.allocateDirect(bitmap.rowBytes * bitmap.height).order(ByteOrder.nativeOrder())
            bitmap.copyPixelsToBuffer(buf)
            buf.rewind()
            return buf
        }
    }
}
