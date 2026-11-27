package com.holistic.holistic_bg

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.holistic.hbr_engine.Exporter
import com.holistic.hbr_engine.Segmenter
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.math.abs

/**
 * On-device checks that the person is kept in front of the new background.
 * Runs against the release build (with R8), exactly like the shipped APK.
 *
 * Test clips come from tools/ci/make_test_media.sh (a portrait of a person
 * in an office): `person.mp4` is upright, `person_rot90.mp4` is stored
 * sideways with a rotation tag like phone camera videos.
 */
@RunWith(AndroidJUnit4::class)
class PersonExportTest {
    private val instr = InstrumentationRegistry.getInstrumentation()
    private val app = instr.targetContext
    private val testAssets = instr.context.assets

    private fun asset(name: String): File {
        val f = File(app.cacheDir, name)
        testAssets.open(name).use { input -> f.outputStream().use { input.copyTo(it) } }
        return f
    }

    @Test(timeout = 240_000)
    fun segmenterFindsThePerson() {
        val bmp = testAssets.open("portrait.jpg").use { BitmapFactory.decodeStream(it) }
        Segmenter(app, landscape = false, video = false).use { seg ->
            val coverage = seg.segmentUpright(bmp).coverage()
            assertTrue("person mask covers only ${pct(coverage)} of the image", coverage > 0.25f)
        }
    }

    @Test(timeout = 240_000)
    fun exportKeepsPersonInFrontOfColor() = checkExport("person.mp4", mapOf("type" to "color", "argb" to GREEN))

    @Test(timeout = 240_000)
    fun exportKeepsPersonInPhoneVideo() = checkExport("person_rot90.mp4", mapOf("type" to "color", "argb" to GREEN))

    @Test(timeout = 240_000)
    fun exportKeepsPersonInFrontOfImage() {
        // A plain green picture as the chosen background image.
        val bg = Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888).apply { eraseColor(GREEN) }
        val f = File(app.cacheDir, "bg.png")
        f.outputStream().use { bg.compress(Bitmap.CompressFormat.PNG, 100, it) }
        checkExport("person_rot90.mp4", mapOf("type" to "image", "path" to f.path))
    }

    @Test(timeout = 240_000)
    fun squareFrameWholeVideo() = checkLayout(
        "person.mp4", mapOf("type" to "color", "argb" to GREEN), mapOf("aspect" to "1:1", "fit" to true),
        expectW = 720, expectH = 720,
    )

    @Test(timeout = 240_000)
    fun landscapeFrameFromPhoneVideoWithZoomedImage() {
        val bg = Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888).apply { eraseColor(GREEN) }
        val f = File(app.cacheDir, "bg2.png")
        f.outputStream().use { bg.compress(Bitmap.CompressFormat.PNG, 100, it) }
        checkLayout(
            "person_rot90.mp4",
            mapOf("type" to "image", "path" to f.path, "scale" to 0.6, "panX" to -1.0, "fill" to GREEN),
            mapOf("aspect" to "16:9", "fit" to true),
            expectW = 1280, expectH = 720,
        )
    }

    /**
     * Guards against "isn't responding": previews with a large photo as the
     * background must never hold up the main thread, and changing only the
     * background must be quick (frame and person mask are reused).
     */
    @Test(timeout = 300_000)
    fun previewNeverFreezesTheScreen() {
        val input = asset("person.mp4")
        val big = Bitmap.createBitmap(4000, 3000, Bitmap.Config.ARGB_8888).apply { eraseColor(GREEN) }
        val photo = File(app.cacheDir, "big_bg.jpg")
        photo.outputStream().use { big.compress(Bitmap.CompressFormat.JPEG, 90, it) }
        big.recycle()

        val main = android.os.Handler(android.os.Looper.getMainLooper())
        val worst = java.util.concurrent.atomic.AtomicLong()
        val running = java.util.concurrent.atomic.AtomicBoolean(true)
        val probe = Thread {
            while (running.get()) {
                val sent = System.nanoTime()
                val done = java.util.concurrent.CountDownLatch(1)
                main.post { done.countDown() }
                done.await(30, java.util.concurrent.TimeUnit.SECONDS)
                worst.set(maxOf(worst.get(), (System.nanoTime() - sent) / 1_000_000))
                Thread.sleep(50)
            }
        }.apply { start() }

        val times = ArrayList<Long>()
        com.holistic.hbr_engine.Previewer(app).use { p ->
            val backgrounds = listOf(
                mapOf("type" to "color", "argb" to GREEN),
                mapOf("type" to "image", "path" to photo.path),
                mapOf("type" to "image", "path" to photo.path, "scale" to 0.7, "panX" to 0.5, "fill" to GREEN),
                mapOf("type" to "color", "argb" to 0xFF0047BB.toInt()),
                mapOf("type" to "blur", "amount" to 0.03),
                mapOf("type" to "image", "path" to photo.path, "scale" to 1.4),
            )
            for (bg in backgrounds) {
                val t0 = System.nanoTime()
                val jpeg = p.render(input.path, 1000, bg, mapOf("aspect" to "9:16"), 960)
                times += (System.nanoTime() - t0) / 1_000_000
                assertTrue("empty preview", jpeg.size > 1000)
            }
        }
        running.set(false)
        probe.join()
        android.util.Log.i("HbrTest", "preview ms: $times, worst main-thread delay ${worst.get()} ms")
        assertTrue("main thread blocked for ${worst.get()} ms during previews", worst.get() < 1000)
        val later = times.drop(1)
        assertTrue("background-only changes are slow: $times", later.average() < maxOf(2500.0, times[0] * 0.9))
    }

    @Test(timeout = 240_000)
    fun musicIsMixedWithTheVoice() {
        val input = asset("person.mp4")
        val music = asset("music.mp3")
        val output = File(app.cacheDir, "music_out.mp4")
        output.delete()
        val settings = mapOf("audio" to mapOf("musicPath" to music.path, "musicVolume" to 0.5, "voiceVolume" to 1.0, "duck" to false))
        Exporter(app, input.path, output.path, mapOf("type" to "color", "argb" to GREEN), settings, { _, _, _ -> }, { false }).run()
        val (pcm, rate) = decodeAudio(output)
        assertTrue("audio too short: ${pcm.size} frames at $rate Hz", pcm.size > rate) // > 1 s (decodeAudio returns one channel)
        val voice = tone(pcm, rate, 440.0)
        val tune = tone(pcm, rate, 880.0)
        val off = tone(pcm, rate, 1234.0)
        assertTrue("voice missing (440 Hz $voice vs noise $off)", voice > off * 20)
        assertTrue("music missing (880 Hz $tune vs noise $off)", tune > off * 20)
    }

    @Test(timeout = 240_000)
    fun originalSoundIsCopiedWhenNoMusic() {
        val input = asset("person.mp4")
        val output = File(app.cacheDir, "nomusic_out.mp4")
        output.delete()
        Exporter(app, input.path, output.path, mapOf("type" to "color", "argb" to GREEN), emptyMap<String, Any>(), { _, _, _ -> }, { false }).run()
        val (pcm, rate) = decodeAudio(output)
        assertTrue("voice missing", tone(pcm, rate, 440.0) > tone(pcm, rate, 1234.0) * 20)
        assertTrue("unexpected music", tone(pcm, rate, 880.0) < tone(pcm, rate, 440.0) / 20)
    }

    @Test(timeout = 480_000)
    fun speechIsRecognisedOnDevice() {
        val input = asset("speech.mp4")
        val meta = com.holistic.hbr_engine.VideoProbe.probe(input.path)
        val pcm = com.holistic.hbr_engine.Transcriber.loadAudio(input.path, meta.audioTrack, meta.durationUs)
        val json = com.holistic.hbr_engine.Transcriber.open(app).use { it.transcribe(pcm, "en", null) }!!
        android.util.Log.i("HbrTest", "transcript: $json")
        val text = json.lowercase()
        assertTrue("speech not recognised: $json", text.contains("country") && text.contains("ask"))
    }

    @Test(timeout = 240_000)
    fun captionsAreBurnedIn() {
        val input = asset("person.mp4")
        val words = listOf("HELLO" to 0, "FROM" to 400, "HOLISTIC" to 800, "BG" to 1200).map { (w, t) ->
            mapOf("w" to w, "t0" to t, "t1" to t + 400)
        }
        val captions = mapOf(
            "enabled" to true,
            "cues" to listOf(mapOf("t0" to 0, "t1" to 2000, "words" to words)),
            "style" to mapOf("preset" to "box", "position" to "bottom", "size" to 1.2),
        )
        val bg = mapOf("type" to "color", "argb" to GREEN)
        val plain = File(app.cacheDir, "cap_plain.mp4").also { it.delete() }
        val withCaps = File(app.cacheDir, "cap_on.mp4").also { it.delete() }
        Exporter(app, input.path, plain.path, bg, emptyMap<String, Any>(), { _, _, _ -> }, { false }).run()
        Exporter(app, input.path, withCaps.path, bg, mapOf("captions" to captions), { _, _, _ -> }, { false }).run()
        val a = frameAt(plain)
        val b = frameAt(withCaps)
        // the bottom fifth should differ (dark box with text), the top must not
        fun diff(y0: Int, y1: Int): Float {
            var d = 0
            var n = 0
            for (y in y0 until y1 step 3) for (x in 0 until a.width step 3) {
                n++
                if (!close(a.getPixel(x, y), b.getPixel(x, y))) d++
            }
            return d.toFloat() / n
        }
        val bottom = diff((a.height * 0.7).toInt(), (a.height * 0.9).toInt())
        val top = diff(0, (a.height * 0.3).toInt())
        assertTrue("caption not visible: bottom changed ${pct(bottom)}", bottom > 0.15f)
        assertTrue("captions leaked into the top: ${pct(top)}", top < 0.02f)
    }

    @Test(timeout = 240_000)
    fun outlineIsDrawnAroundThePerson() {
        val input = asset("person.mp4")
        val bg = mapOf("type" to "color", "argb" to GREEN)
        val output = File(app.cacheDir, "outline_out.mp4").also { it.delete() }
        val settings = mapOf("outline" to mapOf("argb" to (MAGENTA.toLong() and 0xFFFFFFFFL), "width" to 0.02, "glow" to false))
        Exporter(app, input.path, output.path, bg, settings, { _, _, _ -> }, { false }).run()
        val f = frameAt(output)
        var line = 0
        var green = 0
        var total = 0
        for (y in 0 until f.height step 2) for (x in 0 until f.width step 2) {
            total++
            val c = f.getPixel(x, y)
            if (isMagenta(c)) line++ else if (isGreen(c)) green++
        }
        val l = line.toFloat() / total
        assertTrue("outline missing: ${pct(l)} of the frame", l > 0.004f)
        assertTrue("outline too large: ${pct(l)}", l < 0.2f)
        assertTrue("background lost: ${pct(green.toFloat() / total)}", green.toFloat() / total > 0.2f)
        // the preview shows it too
        com.holistic.hbr_engine.Previewer(app).use { p ->
            val jpeg = p.render(input.path, 1000, bg, settings, 640)
            val bmp = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size)
            var n = 0
            for (y in 0 until bmp.height step 2) for (x in 0 until bmp.width step 2) if (isMagenta(bmp.getPixel(x, y))) n++
            assertTrue("outline missing in preview", n > 20)
        }
    }

    @Test(timeout = 300_000)
    fun introAndOutroAreAddedWithAnimations() {
        val input = asset("person_rot90.mp4")
        val red = Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888).apply { eraseColor(0xFFFF0000.toInt()) }
        val pic = File(app.cacheDir, "intro.png")
        pic.outputStream().use { red.compress(Bitmap.CompressFormat.PNG, 100, it) }
        val outro = asset("person.mp4")
        val output = File(app.cacheDir, "seq_out.mp4").also { it.delete() }
        val settings = mapOf(
            "aspect" to "9:16",
            "sequence" to mapOf(
                "before" to listOf(mapOf("kind" to "image", "path" to pic.path, "durationS" to 1.5, "motion" to "in", "transition" to "cut")),
                "after" to listOf(mapOf("kind" to "video", "path" to outro.path, "maxS" to 1.0, "transition" to "circle")),
                "into" to "push", "fadeOut" to true, "transitionS" to 0.3,
            ),
        )
        Exporter(app, input.path, output.path, mapOf("type" to "color", "argb" to GREEN), settings, { _, _, _ -> }, { false }).run()
        val mainS = com.holistic.hbr_engine.VideoProbe.probe(input.path).durationUs / 1e6
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(output.path)
            val durS = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)!!.toLong() / 1000.0
            val want = mainS + 1.5 + 1.0
            assertTrue("length ${durS}s, expected about ${want}s", abs(durS - want) < 0.35)
            fun share(tUs: Long, test: (Int) -> Boolean): Float {
                val f = r.getFrameAtTime(tUs, MediaMetadataRetriever.OPTION_CLOSEST)!!
                var n = 0
                var t = 0
                for (y in 0 until f.height step 4) for (x in 0 until f.width step 4) {
                    t++
                    if (test(f.getPixel(x, y))) n++
                }
                return n.toFloat() / t
            }
            val introRed = share(700_000) { c -> ((c shr 16) and 0xff) > 180 && ((c shr 8) and 0xff) < 80 && (c and 0xff) < 80 }
            assertTrue("intro picture missing: ${pct(introRed)} red", introRed > 0.8f)
            val mainGreen = share(((1.5 + mainS / 2) * 1e6).toLong(), ::isGreen)
            assertTrue("main video missing after the intro: ${pct(mainGreen)} green", mainGreen in 0.2f..0.9f)
            val endDark = share(((want - 0.04) * 1e6).toLong()) { c ->
                ((c shr 16) and 0xff) + ((c shr 8) and 0xff) + (c and 0xff) < 90
            }
            assertTrue("no fade to black at the end: ${pct(endDark)} dark", endDark > 0.6f)
        } finally {
            r.release()
        }
        // the voice starts with the main video, after the intro
        val (pcm, rate) = decodeAudio(output)
        assertTrue("sound too short: ${pcm.size.toDouble() / rate}s", pcm.size.toDouble() / rate > mainS + 2.0)
        var introPeak = 0
        for (i in rate / 10 until rate) introPeak = maxOf(introPeak, abs(pcm[i].toInt()))
        assertTrue("voice heard during the intro (peak $introPeak)", introPeak < 800)
    }

    /** Interleaved 16-bit stereo-or-mono PCM of the first audio track, and its rate. */
    private fun decodeAudio(f: File): Pair<ShortArray, Int> {
        val ex = android.media.MediaExtractor()
        ex.setDataSource(f.path)
        val t = (0 until ex.trackCount).first {
            ex.getTrackFormat(it).getString(android.media.MediaFormat.KEY_MIME)!!.startsWith("audio/")
        }
        ex.selectTrack(t)
        val fmt = ex.getTrackFormat(t)
        val codec = android.media.MediaCodec.createDecoderByType(fmt.getString(android.media.MediaFormat.KEY_MIME)!!)
        codec.configure(fmt, null, null, 0)
        codec.start()
        val out = java.io.ByteArrayOutputStream()
        val info = android.media.MediaCodec.BufferInfo()
        var inEos = false
        var rate = fmt.getInteger(android.media.MediaFormat.KEY_SAMPLE_RATE)
        var ch = fmt.getInteger(android.media.MediaFormat.KEY_CHANNEL_COUNT)
        while (true) {
            if (!inEos) {
                val i = codec.dequeueInputBuffer(10_000)
                if (i >= 0) {
                    val n = ex.readSampleData(codec.getInputBuffer(i)!!, 0)
                    if (n < 0) { codec.queueInputBuffer(i, 0, 0, 0, android.media.MediaCodec.BUFFER_FLAG_END_OF_STREAM); inEos = true }
                    else { codec.queueInputBuffer(i, 0, n, ex.sampleTime, 0); ex.advance() }
                }
            }
            val o = codec.dequeueOutputBuffer(info, 10_000)
            if (o == android.media.MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                rate = codec.outputFormat.getInteger(android.media.MediaFormat.KEY_SAMPLE_RATE)
                ch = codec.outputFormat.getInteger(android.media.MediaFormat.KEY_CHANNEL_COUNT)
            } else if (o >= 0) {
                val b = codec.getOutputBuffer(o)!!
                val bytes = ByteArray(info.size)
                b.position(info.offset); b.get(bytes)
                out.write(bytes)
                codec.releaseOutputBuffer(o, false)
                if ((info.flags and android.media.MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
            }
        }
        codec.stop(); codec.release(); ex.release()
        val sb = java.nio.ByteBuffer.wrap(out.toByteArray()).order(java.nio.ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val all = ShortArray(sb.remaining()).also { sb.get(it) }
        // first channel only
        val mono = ShortArray(all.size / ch) { all[it * ch] }
        return Pair(mono, rate)
    }

    /** Goertzel power of one frequency over the middle second. */
    private fun tone(pcm: ShortArray, rate: Int, freq: Double): Double {
        val start = minOf(pcm.size / 4, rate / 2)
        val n = minOf(rate, pcm.size - start)
        val k = 2 * Math.cos(2 * Math.PI * freq / rate)
        var s1 = 0.0
        var s2 = 0.0
        for (i in 0 until n) {
            val s = pcm[start + i] / 32768.0 + k * s1 - s2
            s2 = s1
            s1 = s
        }
        return s1 * s1 + s2 * s2 - k * s1 * s2
    }

    /** Output has the requested display size and still shows the person. */
    private fun checkLayout(clip: String, background: Map<String, Any>, settings: Map<String, Any>, expectW: Int, expectH: Int) {
        val input = asset(clip)
        val output = File(app.cacheDir, "layout_$clip")
        output.delete()
        Exporter(app, input.path, output.path, background, settings, { _, _, _ -> }, { false }).run()
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(output.path)
            val w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)!!.toInt()
            val h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)!!.toInt()
            val rot = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toInt() ?: 0
            val dw = if (rot % 180 == 0) w else h
            val dh = if (rot % 180 == 0) h else w
            assertTrue("display size ${dw}x$dh, expected ${expectW}x$expectH", dw == expectW && dh == expectH)
            val frame = r.getFrameAtTime(1_000_000, MediaMetadataRetriever.OPTION_CLOSEST)!!
            var green = 0
            var total = 0
            for (y in 0 until frame.height step 4) for (x in 0 until frame.width step 4) {
                total++
                if (isGreen(frame.getPixel(x, y))) green++
            }
            val g = green.toFloat() / total
            assertTrue("person missing: ${pct(g)} of the frame is background", g < 0.9f)
            assertTrue("background missing: only ${pct(g)} is background", g > 0.2f)
        } finally {
            r.release()
        }
    }

    private fun checkExport(clip: String, background: Map<String, Any>) {
        val input = asset(clip)
        val output = File(app.cacheDir, "out_$clip")
        output.delete()
        Exporter(app, input.path, output.path, background, emptyMap<String, Any>(), { _, _, _ -> }, { false }).run()
        assertTrue("no output file", output.length() > 0)

        val src = frameAt(input)
        val out = frameAt(output)
        assertTrue("output size ${out.width}x${out.height} != source ${src.width}x${src.height}",
            out.width == src.width && out.height == src.height)

        var green = 0
        var person = 0
        var total = 0
        for (y in 0 until src.height step 4) for (x in 0 until src.width step 4) {
            val o = out.getPixel(x, y)
            val s = src.getPixel(x, y)
            total++
            if (isGreen(o)) green++ else if (close(o, s)) person++
        }
        val g = green.toFloat() / total
        val p = person.toFloat() / total
        // The portrait is roughly half person, half office background.
        assertTrue("person missing: only ${pct(p)} of the frame shows the person (${pct(g)} is new background)", p > 0.25f)
        assertTrue("old background not replaced: only ${pct(g)} is new background", g > 0.2f)
    }

    private fun frameAt(f: File): Bitmap {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(f.path)
            return r.getFrameAtTime(1_000_000, MediaMetadataRetriever.OPTION_CLOSEST)!!
                .copy(Bitmap.Config.ARGB_8888, false)
        } finally {
            r.release()
        }
    }

    private fun isGreen(c: Int): Boolean {
        val r = (c shr 16) and 0xff
        val g = (c shr 8) and 0xff
        val b = c and 0xff
        return g > 170 && r < 90 && b < 90
    }

    private fun isMagenta(c: Int): Boolean {
        val r = (c shr 16) and 0xff
        val g = (c shr 8) and 0xff
        val b = c and 0xff
        return r > 170 && b > 170 && g < 90
    }

    private fun close(a: Int, b: Int): Boolean {
        val d = abs(((a shr 16) and 0xff) - ((b shr 16) and 0xff)) +
            abs(((a shr 8) and 0xff) - ((b shr 8) and 0xff)) +
            abs((a and 0xff) - (b and 0xff))
        return d < 60
    }

    private fun pct(f: Float) = "${(f * 100).toInt()}%"

    private companion object {
        const val GREEN = 0xFF00FF00.toInt()
        const val MAGENTA = 0xFFFF00FF.toInt()
    }
}
