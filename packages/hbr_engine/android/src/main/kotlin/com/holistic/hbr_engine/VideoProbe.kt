package com.holistic.hbr_engine

import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.os.Build

/** Everything we need to know about a source video to reproduce its quality. */
data class VideoMeta(
    val width: Int,
    val height: Int,
    val rotation: Int,
    val durationUs: Long,
    val frameRate: Float,
    val bitrate: Int,
    val mime: String,
    val hasAudio: Boolean,
    val colorStandard: Int?,
    val colorRange: Int?,
    val colorTransfer: Int?,
    val videoTrack: Int,
    val audioTrack: Int,
) {
    val isHdr: Boolean
        get() = colorTransfer == MediaFormat.COLOR_TRANSFER_ST2084 ||
            colorTransfer == MediaFormat.COLOR_TRANSFER_HLG

    val displayWidth get() = if (rotation % 180 == 0) width else height
    val displayHeight get() = if (rotation % 180 == 0) height else width

    /** Matrix for the core's Y'CbCr math. */
    val matrix: Int
        get() = when (colorStandard) {
            MediaFormat.COLOR_STANDARD_BT601_NTSC, MediaFormat.COLOR_STANDARD_BT601_PAL -> HbrNative.MATRIX_BT601
            MediaFormat.COLOR_STANDARD_BT2020 -> HbrNative.MATRIX_BT2020
            MediaFormat.COLOR_STANDARD_BT709 -> HbrNative.MATRIX_BT709
            else -> if (height >= 720 || width >= 1280) HbrNative.MATRIX_BT709 else HbrNative.MATRIX_BT601
        }

    val fullRange: Boolean get() = colorRange == MediaFormat.COLOR_RANGE_FULL

    val codecName: String
        get() = when (mime) {
            MediaFormat.MIMETYPE_VIDEO_HEVC -> "hevc"
            MediaFormat.MIMETYPE_VIDEO_AVC -> "h264"
            MediaFormat.MIMETYPE_VIDEO_VP9 -> "vp9"
            MediaFormat.MIMETYPE_VIDEO_AV1 -> "av1"
            else -> mime.removePrefix("video/")
        }

    fun toMap(): Map<String, Any> = mapOf(
        "width" to width,
        "height" to height,
        "rotation" to rotation,
        "durationMs" to durationUs / 1000,
        "frameRate" to frameRate.toDouble(),
        "bitrate" to bitrate,
        "codec" to codecName,
        "hasAudio" to hasAudio,
        "isHdr" to isHdr,
    )
}

object VideoProbe {
    fun probe(path: String): VideoMeta {
        val ex = MediaExtractor()
        try {
            ex.setDataSource(path)
            var vt = -1
            var at = -1
            for (i in 0 until ex.trackCount) {
                val mime = ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
                if (vt < 0 && mime.startsWith("video/")) vt = i
                if (at < 0 && mime.startsWith("audio/")) at = i
            }
            require(vt >= 0) { "No video track in $path" }
            val f = ex.getTrackFormat(vt)
            val r = MediaMetadataRetriever()
            val rotation: Int
            val retrieverBitrate: Int
            val retrieverFps: Float
            try {
                r.setDataSource(path)
                rotation = f.intOr("rotation-degrees")
                    ?: r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull()
                    ?: 0
                retrieverBitrate = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toIntOrNull() ?: 0
                retrieverFps = if (Build.VERSION.SDK_INT >= 28) {
                    val frames = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)?.toFloatOrNull()
                    val durMs = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toFloatOrNull()
                    if (frames != null && durMs != null && durMs > 0) frames * 1000f / durMs else 0f
                } else 0f
            } finally {
                r.release()
            }
            val (w, h) = visibleSize(f)
            val fps = f.floatOr(MediaFormat.KEY_FRAME_RATE)?.takeIf { it > 0 }
                ?: retrieverFps.takeIf { it > 0 } ?: 30f
            val audioBitrate = if (at >= 0) ex.getTrackFormat(at).intOr(MediaFormat.KEY_BIT_RATE) ?: 128_000 else 0
            val bitrate = f.intOr(MediaFormat.KEY_BIT_RATE)?.takeIf { it > 0 }
                ?: (retrieverBitrate - audioBitrate).takeIf { it > 0 }
                ?: (w * h * fps * 0.15f).toInt()
            return VideoMeta(
                width = w,
                height = h,
                rotation = ((rotation % 360) + 360) % 360,
                durationUs = if (f.containsKey(MediaFormat.KEY_DURATION)) f.getLong(MediaFormat.KEY_DURATION) else 0L,
                frameRate = fps,
                bitrate = bitrate,
                mime = f.getString(MediaFormat.KEY_MIME)!!,
                hasAudio = at >= 0,
                colorStandard = f.intOr(MediaFormat.KEY_COLOR_STANDARD),
                colorRange = f.intOr(MediaFormat.KEY_COLOR_RANGE),
                colorTransfer = f.intOr(MediaFormat.KEY_COLOR_TRANSFER),
                videoTrack = vt,
                audioTrack = at,
            )
        } finally {
            ex.release()
        }
    }

    /** Frame size without codec padding (crop rectangle if present). */
    fun visibleSize(f: MediaFormat): Pair<Int, Int> {
        val w = f.getInteger(MediaFormat.KEY_WIDTH)
        val h = f.getInteger(MediaFormat.KEY_HEIGHT)
        val l = f.intOr("crop-left")
        val r = f.intOr("crop-right")
        val t = f.intOr("crop-top")
        val b = f.intOr("crop-bottom")
        return if (l != null && r != null && t != null && b != null) {
            Pair(r - l + 1, b - t + 1)
        } else Pair(w, h)
    }
}

fun MediaFormat.intOr(key: String): Int? =
    if (containsKey(key)) try { getInteger(key) } catch (_: Exception) { null } else null

fun MediaFormat.floatOr(key: String): Float? {
    if (!containsKey(key)) return null
    return try {
        getFloat(key)
    } catch (_: Exception) {
        try { getInteger(key).toFloat() } catch (_: Exception) { null }
    }
}
