package com.holistic.hbr_engine

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.text.Layout
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextPaint
import android.text.style.ForegroundColorSpan
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** One caption on screen: a few words shown together. Times in ms. */
class Cue(val t0: Long, val t1: Long, val words: List<Word>) {
    class Word(val text: String, val t0: Long, val t1: Long)
}

/**
 * Caption look. preset: "pop" (bold, outlined, spoken word highlighted),
 * "box" (text on a dark rounded box), "clean" (soft shadow), "karaoke"
 * (words light up as they are spoken).
 */
data class CaptionStyle(
    val preset: String = "pop",
    val position: String = "bottom",
    val size: Float = 1f,
    val textColor: Int = Color.WHITE,
    val highlightColor: Int = 0xFFFFD60A.toInt(),
    val uppercase: Boolean = false,
)

/**
 * Draws burned-in captions. Each caption is rendered upright once per
 * highlighted word (cached), rotated into the video's stored orientation and
 * blended into the frame.
 */
class CaptionRenderer(
    private val cues: List<Cue>,
    private val style: CaptionStyle,
    /** Upright (display) size of the output frame. */
    private val dispW: Int,
    private val dispH: Int,
    /** Clockwise display rotation of the output (stored frame = display rotated back). */
    private val rotation: Int,
    private val matrix: Int,
    private val full: Boolean,
) {
    private class Sprite(val rgba: ByteBuffer, val w: Int, val h: Int, val x: Int, val y: Int)

    private val cache = object : LinkedHashMap<Long, Sprite>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Long, Sprite>) = size > 12
    }
    private var cursor = 0

    private val short = minOf(dispW, dispH)
    private val fontPx = (short * 0.062f * style.size.coerceIn(0.5f, 2f)).coerceAtLeast(12f)
    private val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = fontPx
        typeface = when (this@CaptionRenderer.style.preset) {
            "clean" -> Typeface.create("sans-serif-medium", Typeface.NORMAL)
            else -> Typeface.create("sans-serif-black", Typeface.BOLD)
        }
        letterSpacing = if (this@CaptionRenderer.style.preset == "pop") 0.01f else 0f
    }

    /** Draws the caption for time [tMs] into the destination planes (stored orientation, dw x dh). */
    fun draw(
        tMs: Long, dy: ByteBuffer, dyStride: Int, du: ByteBuffer, dv: ByteBuffer, duvStride: Int, duvPix: Int,
        dw: Int, dh: Int,
    ) {
        val i = cueAt(tMs)
        if (i < 0) return
        val cue = cues[i]
        val active = if (style.preset == "clean") -1
        else cue.words.indexOfLast { it.t0 <= tMs }.coerceAtLeast(0)
        val key = (i.toLong() shl 16) or (active + 1).toLong()
        val s = cache.getOrPut(key) { render(cue, active) }
        HbrNative.nativeOverlay(dy, dyStride, du, dv, duvStride, duvPix, dw, dh, s.rgba, s.w, s.h, s.w * 4, s.x, s.y, true, matrix, full)
    }

    fun drawInto(tMs: Long, dst: I420Frame) =
        draw(tMs, dst.y, dst.width, dst.u, dst.v, dst.chromaWidth, 1, dst.width, dst.height)

    private fun cueAt(t: Long): Int {
        if (cues.isEmpty()) return -1
        if (cursor >= cues.size || cues[cursor].t0 > t) cursor = 0
        while (cursor < cues.size && cues[cursor].t1 <= t) cursor++
        return if (cursor < cues.size && cues[cursor].t0 <= t) cursor else -1
    }

    private fun render(cue: Cue, active: Int): Sprite {
        val sb = SpannableStringBuilder()
        val spans = ArrayList<IntArray>()
        cue.words.forEachIndexed { k, w ->
            if (k > 0) sb.append(' ')
            val start = sb.length
            sb.append(if (style.uppercase) w.text.uppercase() else w.text)
            spans += intArrayOf(start, sb.length)
        }
        val maxW = (dispW * 0.86f).toInt()
        fun layout(p: TextPaint, text: CharSequence) =
            StaticLayout.Builder.obtain(text, 0, text.length, p, maxW)
                .setAlignment(Layout.Alignment.ALIGN_CENTER)
                .setLineSpacing(0f, 1.05f)
                .setIncludePad(false)
                .build()

        val fill = SpannableStringBuilder(sb)
        when (style.preset) {
            "karaoke" -> spans.forEachIndexed { k, r ->
                val c = if (k <= active) style.highlightColor else (style.textColor and 0x00FFFFFF) or 0x99000000.toInt()
                fill.setSpan(ForegroundColorSpan(c), r[0], r[1], Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            "clean" -> {}
            else -> if (active >= 0 && active < spans.size) {
                val r = spans[active]
                fill.setSpan(ForegroundColorSpan(style.highlightColor), r[0], r[1], Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
        }
        paint.color = style.textColor
        paint.style = Paint.Style.FILL
        val text = layout(paint, fill)
        var tw = 0f
        for (l in 0 until text.lineCount) tw = maxOf(tw, text.getLineWidth(l))
        val pad = (fontPx * 0.45f).toInt()
        val w = (tw + 2 * pad).toInt().coerceAtLeast(2) and 1.inv()
        val h = (text.height + 2 * pad).coerceAtLeast(2) and 1.inv()
        val upright = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val c = Canvas(upright)
        val dx = pad - (maxW - tw) / 2f
        when (style.preset) {
            "box" -> {
                val bg = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xB3000000.toInt() }
                c.drawRoundRect(RectF(0f, 0f, w.toFloat(), h.toFloat()), fontPx * 0.35f, fontPx * 0.35f, bg)
            }
            "clean" -> paint.setShadowLayer(fontPx * 0.18f, 0f, fontPx * 0.06f, 0xCC000000.toInt())
            else -> { // outline for pop / karaoke
                val stroke = TextPaint(paint).apply {
                    style = Paint.Style.STROKE
                    strokeWidth = fontPx * 0.16f
                    strokeJoin = Paint.Join.ROUND
                    color = Color.BLACK
                    clearShadowLayer()
                }
                c.save()
                c.translate(dx, pad.toFloat())
                layout(stroke, sb.toString()).draw(c)
                c.restore()
            }
        }
        c.save()
        c.translate(dx, pad.toFloat())
        text.draw(c)
        c.restore()
        paint.clearShadowLayer()

        // position on the upright frame
        val cy = when (style.position) {
            "top" -> 0.16f
            "middle" -> 0.5f
            else -> 0.80f
        }
        val xd = ((dispW - w) / 2) and 1.inv()
        val yd = ((dispH * cy - h / 2f).toInt().coerceIn(0, maxOf(0, dispH - h))) and 1.inv()

        // into stored orientation
        val bmp = if (rotation == 0) upright else Bitmap.createBitmap(
            upright, 0, 0, w, h, Matrix().apply { postRotate(-rotation.toFloat()) }, true,
        ).also { upright.recycle() }
        val sw = if (rotation % 180 == 0) dispW else dispH
        val sh = if (rotation % 180 == 0) dispH else dispW
        val (xs, ys) = when (rotation) {
            90 -> yd to sh - (xd + w)
            180 -> sw - (xd + w) to sh - (yd + h)
            270 -> sw - (yd + h) to xd
            else -> xd to yd
        }
        val buf = ByteBuffer.allocateDirect(bmp.rowBytes * bmp.height).order(ByteOrder.nativeOrder())
        bmp.copyPixelsToBuffer(buf)
        buf.rewind()
        val sprite = Sprite(buf, bmp.rowBytes / 4, bmp.height, xs, ys)
        bmp.recycle()
        return sprite
    }

    companion object {
        /** Parses the Dart `Captions.toMap()`; null when captions are off. */
        fun from(settings: Map<*, *>, dispW: Int, dispH: Int, rotation: Int, matrix: Int, full: Boolean): CaptionRenderer? {
            val m = settings["captions"] as? Map<*, *> ?: return null
            if (m["enabled"] == false) return null
            val cues = (m["cues"] as? List<*>)?.mapNotNull { c ->
                val cm = c as? Map<*, *> ?: return@mapNotNull null
                val words = (cm["words"] as? List<*>)?.mapNotNull { w ->
                    val wm = w as? Map<*, *> ?: return@mapNotNull null
                    Cue.Word(wm["w"] as? String ?: "", (wm["t0"] as Number).toLong(), (wm["t1"] as Number).toLong())
                }.orEmpty().filter { it.text.isNotBlank() }
                if (words.isEmpty()) null
                else Cue((cm["t0"] as? Number)?.toLong() ?: words.first().t0, (cm["t1"] as? Number)?.toLong() ?: words.last().t1, words)
            }.orEmpty().sortedBy { it.t0 }
            if (cues.isEmpty()) return null
            val s = m["style"] as? Map<*, *> ?: emptyMap<String, Any>()
            val style = CaptionStyle(
                s["preset"] as? String ?: "pop",
                s["position"] as? String ?: "bottom",
                (s["size"] as? Number)?.toFloat() ?: 1f,
                (s["textColor"] as? Number)?.toInt() ?: Color.WHITE,
                (s["highlightColor"] as? Number)?.toInt() ?: 0xFFFFD60A.toInt(),
                s["uppercase"] as? Boolean ?: false,
            )
            return CaptionRenderer(cues, style, dispW, dispH, rotation, matrix, full)
        }
    }
}
