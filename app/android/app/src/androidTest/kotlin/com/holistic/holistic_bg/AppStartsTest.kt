package com.holistic.holistic_bg

import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

/** The installed app must open and stay open (cold start of the real activity). */
@RunWith(AndroidJUnit4::class)
class AppStartsTest {
    @Test(timeout = 120_000)
    fun appOpensAndStaysOpen() {
        ActivityScenario.launch(MainActivity::class.java).use { s ->
            Thread.sleep(8_000) // Flutter engine start, first frame, plugins registered
            assertEquals(Lifecycle.State.RESUMED, s.state)
            var alive = false
            s.onActivity { a -> alive = !a.isFinishing && !a.isDestroyed }
            assertEquals("the app closed itself after starting", true, alive)
        }
    }
}
