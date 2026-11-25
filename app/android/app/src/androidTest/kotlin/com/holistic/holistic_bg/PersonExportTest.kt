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

    @Test
    fun segmenterFindsThePerson() {
        val bmp = testAssets.open("portrait.jpg").use { BitmapFactory.decodeStream(it) }
        Segmenter(app, landscape = false, video = false).use { seg ->
            val coverage = seg.segmentUpright(bmp).coverage()
            assertTrue("person mask covers only ${pct(coverage)} of the image", coverage > 0.25f)
        }
    }

    @Test
    fun exportKeepsPersonInFrontOfColor() = checkExport("person.mp4", mapOf("type" to "color", "argb" to GREEN))

    @Test
    fun exportKeepsPersonInPhoneVideo() = checkExport("person_rot90.mp4", mapOf("type" to "color", "argb" to GREEN))

    @Test
    fun exportKeepsPersonInFrontOfImage() {
        // A plain green picture as the chosen background image.
        val bg = Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888).apply { eraseColor(GREEN) }
        val f = File(app.cacheDir, "bg.png")
        f.outputStream().use { bg.compress(Bitmap.CompressFormat.PNG, 100, it) }
        checkExport("person_rot90.mp4", mapOf("type" to "image", "path" to f.path))
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

    private fun close(a: Int, b: Int): Boolean {
        val d = abs(((a shr 16) and 0xff) - ((b shr 16) and 0xff)) +
            abs(((a shr 8) and 0xff) - ((b shr 8) and 0xff)) +
            abs((a and 0xff) - (b and 0xff))
        return d < 60
    }

    private fun pct(f: Float) = "${(f * 100).toInt()}%"

    private companion object {
        const val GREEN = 0xFF00FF00.toInt()
    }
}
