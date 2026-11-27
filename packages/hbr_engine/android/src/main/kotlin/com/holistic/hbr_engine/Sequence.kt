package com.holistic.hbr_engine

import kotlin.math.roundToLong

/** The animations between parts (same ids and codes as the web app and the C core). */
object Transitions {
    private val codes = mapOf(
        "cut" to 0, "fade" to 1, "black" to 2, "flash" to 3, "slide" to 4, "push" to 5, "up" to 6,
        "zoomin" to 7, "zoomout" to 8, "circle" to 9, "wipe" to 10, "spin" to 11,
    )
    fun code(id: String?): Int = codes[id] ?: 1
}

/** A picture or video shown before or after the main video. */
data class ClipSpec(
    val kind: String,
    val path: String,
    val durationS: Float = 3f,
    /** "none", "in" (slow zoom in) or "out" (slow zoom out); pictures only. */
    val motion: String = "in",
    /** true: whole picture over a blurred copy; false: fills the frame. */
    val fit: Boolean = false,
    /** Animation into this clip. */
    val transition: String = "fade",
    val maxS: Float = 60f,
) {
    val isVideo get() = kind == "video"

    /** Planned length in µs (videos: their length, at most [maxS]). */
    val lengthUs: Long by lazy {
        if (isVideo) minOf(VideoProbe.probe(path).durationUs, (maxS * 1e6).roundToLong()).coerceAtLeast(0L)
        else (durationS.coerceIn(0.5f, 60f) * 1e6).roundToLong()
    }

    companion object {
        fun from(m: Map<*, *>): ClipSpec? {
            val path = (m["path"] as? String)?.takeIf { it.isNotEmpty() } ?: return null
            return ClipSpec(
                if (m["kind"] == "video") "video" else "image",
                path,
                (m["durationS"] as? Number)?.toFloat() ?: 3f,
                m["motion"] as? String ?: "in",
                m["fit"] as? Boolean ?: false,
                m["transition"] as? String ?: "fade",
                (m["maxS"] as? Number)?.toFloat() ?: 60f,
            )
        }
    }
}

/** Intro and outro clips plus the animations around the main video. */
data class SequenceSpec(
    val before: List<ClipSpec> = emptyList(),
    val after: List<ClipSpec> = emptyList(),
    /** Animation from the last intro clip into the main video. */
    val into: String = "fade",
    val fadeIn: Boolean = false,
    val fadeOut: Boolean = false,
    val transitionS: Float = 0.8f,
) {
    val hasClips get() = before.isNotEmpty() || after.isNotEmpty()
    val active get() = hasClips || fadeIn || fadeOut
    val introUs get() = before.sumOf { it.lengthUs }
    val outroUs get() = after.sumOf { it.lengthUs }

    companion object {
        fun from(settings: Map<*, *>): SequenceSpec {
            val s = settings["sequence"] as? Map<*, *> ?: return SequenceSpec()
            fun list(k: String) = (s[k] as? List<*>)?.mapNotNull { (it as? Map<*, *>)?.let(ClipSpec::from) } ?: emptyList()
            return SequenceSpec(
                list("before"), list("after"),
                s["into"] as? String ?: "fade",
                s["fadeIn"] as? Boolean ?: false,
                s["fadeOut"] as? Boolean ?: false,
                ((s["transitionS"] as? Number)?.toFloat() ?: 0.8f).coerceIn(0.1f, 3f),
            )
        }
    }
}

/**
 * Puts output frames in order with the chosen animations: each part enters
 * over [trUs] from the last frame of the part before it (or from black), and
 * the film can end by fading to black.
 */
class Sequencer(
    private val w: Int, private val h: Int, private val rotation: Int, blackYuv: Int,
    private val trUs: Long, private val fadeOut: Boolean, var endUs: Long,
) {
    private val prev = I420Frame(w, h)
    private val out = I420Frame(w, h)
    private val out2 = I420Frame(w, h)
    private val black = I420Frame(w, h)
    private var type = 0
    private var startUs = 0L
    private var last: I420Frame? = null

    init {
        HbrNative.nativeFill(black.buffer, w, h, blackYuv)
        HbrNative.nativeFill(prev.buffer, w, h, blackYuv)
    }

    /** A new part starts at output time [atUs], entering with animation [id]. */
    fun begin(id: String, atUs: Long) {
        type = Transitions.code(id)
        startUs = atUs
    }

    /** The frame to encode at output time [outUs] for the part's own frame [cur]. */
    fun frame(cur: I420Frame, outUs: Long): I420Frame {
        var f = cur
        val local = outUs - startUs
        if (type != 0 && local < trUs) {
            check(HbrNative.nativeTransition(prev.buffer, f.buffer, out.buffer, w, h, rotation, type,
                (local.coerceAtLeast(0L).toFloat() / trUs)) == 0) { "transition failed" }
            f = out
        }
        if (fadeOut && endUs > 0 && outUs > endUs - trUs) {
            val t = ((outUs - (endUs - trUs)).toFloat() / trUs).coerceIn(0f, 1f)
            check(HbrNative.nativeTransition(f.buffer, black.buffer, out2.buffer, w, h, rotation, 1, t) == 0) { "fade failed" }
            f = out2
        }
        last = f
        return f
    }

    /** Freezes the last shown frame as the start of the next animation. */
    fun hold() {
        val l = last ?: return
        val src = l.buffer.duplicate().also { it.clear() }
        val dst = prev.buffer.duplicate().also { it.clear() }
        dst.put(src)
    }
}

/** Renders the frames of an intro/outro clip on the output canvas (stored orientation). */
class ClipRenderer(
    private val cw: Int, private val ch: Int, private val rotation: Int,
    private val matrix: Int, private val full: Boolean,
) {
    private val dispW = if (rotation % 180 == 0) cw else ch
    private val dispH = if (rotation % 180 == 0) ch else cw
    private val upright = I420Frame(dispW, dispH)
    private val stored = if (rotation == 0) upright else I420Frame(cw, ch)
    private val zoomed by lazy { I420Frame(cw, ch) }

    /**
     * Calls [emit] for each frame with the clip-local time and duration (µs).
     * Pictures are shown at [fps]; videos keep their own frame times.
     */
    fun render(clip: ClipSpec, fps: Float, isCancelled: () -> Boolean, emit: (I420Frame, Long, Long) -> Unit) {
        val total = clip.lengthUs
        if (total <= 0) return
        if (!clip.isVideo) {
            val bmp = BackgroundSource.loadBitmap(clip.path, (maxOf(dispW, dispH) * 1.2f).toInt())
            val iw = maxOf(2, bmp.width and 1.inv())
            val ih = maxOf(2, bmp.height and 1.inv())
            val img = I420Frame(iw, ih)
            val argb = if (bmp.config == android.graphics.Bitmap.Config.ARGB_8888) bmp else bmp.copy(android.graphics.Bitmap.Config.ARGB_8888, false)
            HbrNative.nativeRgbaToI420Fill(BackgroundSource.bitmapToRgba(argb), argb.width, argb.height, argb.rowBytes,
                img.buffer, iw, ih, matrix, full)
            bmp.recycle()
            place(img, clip.fit)
            val dur = (1e6 / fps.coerceIn(1f, 240f)).roundToLong()
            val n = maxOf(1L, total / dur)
            for (i in 0 until n) {
                if (isCancelled()) throw ExportCancelled()
                var f = stored
                if (clip.motion == "in" || clip.motion == "out") {
                    val p = i.toFloat() / maxOf(1L, n - 1)
                    val z = 0.14f * (if (clip.motion == "in") p else 1f - p)
                    HbrNative.nativeZoom(stored.buffer, zoomed.buffer, cw, ch, 1f + z)
                    f = zoomed
                }
                emit(f, i * dur, dur)
            }
            return
        }
        FrameDecoder(clip.path).use { dec ->
            val turn = dec.meta.rotation
            val up = if (turn == 0) null else I420Frame(
                if (turn % 180 == 0) dec.width else dec.height, if (turn % 180 == 0) dec.height else dec.width,
            )
            val dur = (1e6 / dec.meta.frameRate.coerceIn(1f, 240f)).roundToLong()
            var first = -1L
            while (dec.next()) {
                if (isCancelled()) throw ExportCancelled()
                if (first < 0) first = dec.ptsUs
                val local = dec.ptsUs - first
                if (local + dur / 2 >= total) break
                val src = if (up == null) dec.frame else up.also {
                    HbrNative.nativeRotateI420(dec.frame.buffer, dec.width, dec.height, it.buffer, turn)
                }
                place(src, clip.fit)
                emit(stored, local, dur)
            }
        }
    }

    /** Upright picture onto the canvas (cover, or whole over a blurred, darker copy), then stored orientation. */
    private fun place(img: I420Frame, fit: Boolean) {
        val cover = HbrNative.placeRect(img.width, img.height, dispW, dispH, false)
        if (fit) {
            HbrNative.blit(img, upright, cover)
            HbrNative.nativeBlur(upright.buffer, dispW, dispH, 0.04f)
            val y = upright.buffer
            val lo = if (full) 0 else 16
            for (i in 0 until dispW * dispH) {
                val v = y.get(i).toInt() and 0xff
                y.put(i, (lo + (v - lo) * 7 / 10).coerceIn(0, 255).toByte())
            }
            HbrNative.blit(img, upright, HbrNative.placeRect(img.width, img.height, dispW, dispH, true))
        } else {
            HbrNative.blit(img, upright, cover)
        }
        if (rotation != 0) {
            HbrNative.nativeRotateI420(upright.buffer, dispW, dispH, stored.buffer, (360 - rotation) % 360)
        }
    }
}
