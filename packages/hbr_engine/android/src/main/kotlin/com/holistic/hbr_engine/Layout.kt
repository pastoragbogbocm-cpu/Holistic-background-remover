package com.holistic.hbr_engine

import kotlin.math.roundToInt

/**
 * Output frame shape. The canvas is computed in display orientation (what the
 * viewer sees) and then expressed in the stored orientation of the source,
 * because the output keeps the source's rotation tag.
 *
 * The person's video sits centred on the canvas: `fit` shows all of it (the
 * new background fills the rest), otherwise it covers the canvas (cropped).
 */
class Layout(
    val srcW: Int,
    val srcH: Int,
    val rotation: Int,
    aspect: String?,
    val fit: Boolean,
) {
    val canvasW: Int
    val canvasH: Int
    /** Where the source video lands on the canvas (stored orientation). */
    val personRect: Rect4
    val identity: Boolean

    init {
        val sideways = rotation % 180 != 0
        val dispW = if (sideways) srcH else srcW
        val dispH = if (sideways) srcW else srcH
        val ratio = parseAspect(aspect)
        var cw: Int
        var ch: Int
        if (ratio == null) {
            cw = dispW
            ch = dispH
        } else {
            // Same short side as the source: no upscaling of the person.
            val short = minOf(dispW, dispH)
            if (ratio >= 1f) {
                ch = short
                cw = even(short * ratio)
            } else {
                cw = short
                ch = even(short / ratio)
            }
        }
        canvasW = if (sideways) ch else cw
        canvasH = if (sideways) cw else ch
        identity = canvasW == srcW && canvasH == srcH
        personRect = if (identity) Rect4(0, 0, srcW, srcH)
        else HbrNative.placeRect(srcW, srcH, canvasW, canvasH, fit)
    }

    companion object {
        fun from(settings: Map<*, *>, srcW: Int, srcH: Int, rotation: Int) =
            Layout(srcW, srcH, rotation, settings["aspect"] as? String, settings["fit"] as? Boolean ?: false)

        fun parseAspect(a: String?): Float? {
            if (a == null || a == "original") return null
            val p = a.split(":")
            if (p.size != 2) return null
            val x = p[0].toFloatOrNull() ?: return null
            val y = p[1].toFloatOrNull() ?: return null
            if (x <= 0f || y <= 0f) return null
            return x / y
        }

        private fun even(v: Float) = maxOf(2, (v / 2f).roundToInt() * 2)
    }
}

/**
 * How the background picture or video sits behind the person, in display
 * orientation: [scale] 1 = exactly covers the frame (smaller shows [fillArgb]
 * around it, larger zooms in), [panX]/[panY] -1..1 choose which part shows
 * (or where a smaller picture sits).
 */
data class BgTransform(val scale: Float = 1f, val panX: Float = 0f, val panY: Float = 0f, val fillArgb: Int = 0xFF000000.toInt()) {
    val identity get() = scale == 1f && panX == 0f && panY == 0f

    companion object {
        fun from(spec: Map<*, *>) = BgTransform(
            (spec["scale"] as? Number)?.toFloat() ?: 1f,
            (spec["panX"] as? Number)?.toFloat() ?: 0f,
            (spec["panY"] as? Number)?.toFloat() ?: 0f,
            (spec["fill"] as? Number)?.toInt() ?: 0xFF000000.toInt(),
        )
    }
}

/**
 * Puts the person in front of the background on the output canvas. When the
 * canvas is the source frame (the usual case) this is a single composite,
 * exactly as before; otherwise the person layer is composited at source
 * resolution against the matching part of the background and then placed.
 */
class Compositor(
    private val engine: MatteEngine,
    private val layout: Layout,
    private val matrix: Int,
    private val full: Boolean,
) {
    private val cw = layout.canvasW
    private val ch = layout.canvasH
    private val canvas by lazy { I420Frame(cw, ch) }
    private val srcBg by lazy { I420Frame(layout.srcW, layout.srcH) }
    private val person by lazy { I420Frame(layout.srcW, layout.srcH) }
    private var solidYuv = Int.MIN_VALUE
    private val coverRect by lazy { HbrNative.placeRect(layout.srcW, layout.srcH, cw, ch, false) }

    /** Composites into destination planes of size canvasW x canvasH. */
    fun compose(
        src: I420Frame, bg: BackgroundFrame,
        dy: java.nio.ByteBuffer, dyStride: Int, du: java.nio.ByteBuffer, dv: java.nio.ByteBuffer,
        duvStride: Int, duvPix: Int,
    ) {
        if (layout.identity) {
            engine.composite(src, dy, dyStride, du, dv, duvStride, duvPix, bg)
            return
        }
        val r = layout.personRect
        // 1. background on the whole canvas
        when (bg.mode) {
            HbrNative.MODE_IMAGE -> {
                val img = bg.image!!
                check(img.width == cw && img.height == ch) { "background is ${img.width}x${img.height}, canvas ${cw}x$ch" }
                HbrNative.blit(img, canvas, Rect4(0, 0, cw, ch))
            }
            HbrNative.MODE_COLOR -> if (solidYuv != bg.yuvColor) {
                HbrNative.nativeFill(canvas.buffer, cw, ch, bg.yuvColor)
                solidYuv = bg.yuvColor
            }
            HbrNative.MODE_BLUR -> {
                // blurred copy of the frame covering the canvas
                HbrNative.blit(src, canvas, coverRect)
                HbrNative.nativeBlur(canvas.buffer, cw, ch, bg.blur * 1.5f)
            }
        }
        // 2. person layer at source resolution, against the background behind it
        if (bg.mode == HbrNative.MODE_BLUR) {
            engine.compositeInto(src, person, bg)
        } else {
            check(HbrNative.nativeCrop(canvas.buffer, cw, ch, r.x, r.y, r.w, r.h, srcBg.buffer, srcBg.width, srcBg.height) == 0)
            engine.compositeInto(src, person, BackgroundFrame(HbrNative.MODE_IMAGE, image = srcBg))
        }
        // 3. canvas, then the person layer on top, into the destination
        check(HbrNative.nativeBlit(canvas.buffer, cw, ch, dy, dyStride, du, dv, duvStride, duvPix, cw, ch, 0, 0, cw, ch) == 0)
        check(HbrNative.nativeBlit(person.buffer, person.width, person.height, dy, dyStride, du, dv, duvStride, duvPix,
            cw, ch, r.x, r.y, r.w, r.h) == 0)
    }

    fun composeInto(src: I420Frame, dst: I420Frame, bg: BackgroundFrame) =
        compose(src, bg, dst.y, dst.width, dst.u, dst.v, dst.chromaWidth, 1)
}
