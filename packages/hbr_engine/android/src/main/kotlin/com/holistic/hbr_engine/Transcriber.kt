package com.holistic.hbr_engine

import android.content.Context
import java.io.File

/**
 * On-device speech recognition (whisper.cpp, model bundled in the app) for
 * captions. Returns words with times; nothing leaves the phone.
 */
class Transcriber private constructor(private var handle: Long) : AutoCloseable {
    fun interface Listener {
        /** Return true to cancel. */
        fun onProgress(percent: Int): Boolean
    }

    /** JSON array of {"w","t0","t1"} (milliseconds), or null if cancelled. */
    fun transcribe(pcm16k: FloatArray, language: String, listener: Listener?): String? {
        val threads = Runtime.getRuntime().availableProcessors().coerceIn(1, 4)
        return nativeTranscribe(handle, pcm16k, language, threads, listener)
    }

    override fun close() {
        if (handle != 0L) nativeDestroy(handle)
        handle = 0L
    }

    companion object {
        const val MODEL = "ggml-base-q5_1.bin"

        init {
            HbrNative // loads libhbr_jni
        }

        @JvmStatic private external fun nativeLoad(path: String): Long
        @JvmStatic private external fun nativeDestroy(handle: Long)
        @JvmStatic private external fun nativeTranscribe(
            handle: Long, pcm: FloatArray, language: String, threads: Int, listener: Listener?,
        ): String?

        /** Copies the bundled model to app storage once (whisper reads it from a file). */
        fun open(context: Context): Transcriber {
            val dir = File(context.filesDir, "models").apply { mkdirs() }
            val f = File(dir, MODEL)
            val size = try { context.assets.openFd(MODEL).use { it.length } } catch (_: Exception) { -1L }
            if (!f.exists() || (size >= 0 && f.length() != size)) {
                val tmp = File(dir, "$MODEL.part")
                context.assets.open(MODEL).use { i -> tmp.outputStream().use { i.copyTo(it, 1 shl 20) } }
                check(tmp.renameTo(f)) { "Could not install the speech model" }
            }
            val h = nativeLoad(f.path)
            check(h != 0L) { "Could not load the speech model" }
            return Transcriber(h)
        }

        /** The video's sound as 16 kHz mono float samples (what Whisper expects). */
        fun loadAudio(path: String, track: Int, durationUs: Long): FloatArray {
            require(track >= 0) { "This video has no sound to caption" }
            val rate = 16000
            val total = (durationUs * rate / 1_000_000L).toInt().coerceAtLeast(1)
            val out = FloatArray(total)
            Stream({ PcmReader(path, track) }, rate, 1, loop = false).use { s ->
                val chunk = FloatArray(4096)
                var pos = 0
                while (pos < total) {
                    val n = minOf(4096, total - pos)
                    s.fill(chunk, n)
                    System.arraycopy(chunk, 0, out, pos, n)
                    pos += n
                }
            }
            return out
        }
    }
}
