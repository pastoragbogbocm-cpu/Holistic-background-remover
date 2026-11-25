package com.holistic.holistic_bg

import android.content.Intent
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Opens the real editor with a video and a large photo as the background
 * (what a person does in the app) and checks the screen never stops
 * responding: the main thread must keep answering within a second.
 */
@RunWith(AndroidJUnit4::class)
class EditorFreezeTest {
    private val instr = InstrumentationRegistry.getInstrumentation()
    private val app = instr.targetContext

    @Test(timeout = 180_000)
    fun openingTheEditorDoesNotFreeze() = checkEditor(withPicture = false)

    @Test(timeout = 180_000)
    fun addingAPictureBackgroundDoesNotFreeze() = checkEditor(withPicture = true)

    private fun checkEditor(withPicture: Boolean) {
        val video = File(app.cacheDir, "editor_person.mp4")
        instr.context.assets.open("person.mp4").use { i -> video.outputStream().use { i.copyTo(it) } }
        val photo = File(app.cacheDir, "editor_bg.jpg")
        Bitmap.createBitmap(4000, 3000, Bitmap.Config.ARGB_8888).apply {
            eraseColor(0xFF2E7D32.toInt())
            photo.outputStream().use { compress(Bitmap.CompressFormat.JPEG, 92, it) }
            recycle()
        }

        val main = Handler(Looper.getMainLooper())
        val worst = AtomicLong()
        val running = AtomicBoolean(true)
        val probe = Thread {
            while (running.get()) {
                val sent = System.nanoTime()
                val done = CountDownLatch(1)
                main.post { done.countDown() }
                if (!done.await(1200, TimeUnit.MILLISECONDS)) {
                    // stuck: record where the main thread is, to find the cause
                    val st = Looper.getMainLooper().thread.stackTrace.take(40).joinToString("\n  at ")
                    android.util.Log.w("HbrTest", "main thread busy >1.2 s:\n  at $st")
                    // what is waiting in the main queue (shows a stuck sync barrier, if any)
                    val sb = StringBuilder()
                    Looper.getMainLooper().dump({ line -> sb.append(line).append('\n') }, "  ")
                    android.util.Log.w("HbrTest", "main queue:\n" + sb.toString().take(6000))
                    done.await(60, TimeUnit.SECONDS)
                }
                worst.set(maxOf(worst.get(), (System.nanoTime() - sent) / 1_000_000))
                Thread.sleep(100)
            }
        }

        val intent = Intent(app, MainActivity::class.java).putExtra("video", video.path)
        if (withPicture) intent.putExtra("image", photo.path)
        ActivityScenario.launch<MainActivity>(intent).use { s ->
            Thread.sleep(3_000) // app start (measured separately by AppStartsTest)
            worst.set(0)
            probe.start()
            Thread.sleep(25_000) // editor opens, first preview with the picture, settles
            running.set(false)
            probe.join()
            android.util.Log.i("HbrTest", "editor (picture=$withPicture): worst main-thread delay ${worst.get()} ms")
            assertEquals(Lifecycle.State.RESUMED, s.state)
            assertTrue("screen stopped responding for ${worst.get()} ms after adding the background", worst.get() < 1500)
        }
    }
}
