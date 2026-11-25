package com.holistic.hbr_engine

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.tanh

/** What the user chose for the soundtrack. */
data class AudioMix(
    val musicPath: String?,
    val musicVolume: Float = 0.3f,
    val voiceVolume: Float = 1f,
    /** Lower the music automatically while the person is talking. */
    val duck: Boolean = true,
    /** Where in the song the music starts (and loops back to), in ms. */
    val musicStartMs: Long = 0,
) {
    /** Nothing to mix: the original audio is copied bit for bit, as before. */
    val passthrough get() = musicPath == null && voiceVolume == 1f

    companion object {
        fun from(settings: Map<*, *>): AudioMix {
            val a = settings["audio"] as? Map<*, *> ?: return AudioMix(null)
            return AudioMix(
                (a["musicPath"] as? String)?.takeIf { it.isNotEmpty() },
                (a["musicVolume"] as? Number)?.toFloat() ?: 0.3f,
                (a["voiceVolume"] as? Number)?.toFloat() ?: 1f,
                a["duck"] as? Boolean ?: true,
                ((a["musicStartMs"] as? Number)?.toLong() ?: 0L).coerceAtLeast(0L),
            )
        }
    }
}

/**
 * Decodes one audio track to interleaved 16-bit PCM, in chunks.
 */
internal class PcmReader(path: String, track: Int?, private val startUs: Long = 0) : AutoCloseable {
    private val ex = MediaExtractor().apply { setDataSource(path) }
    private val trackIndex: Int = track ?: (0 until ex.trackCount).firstOrNull {
        ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
    } ?: throw IllegalArgumentException("No audio in ${File(path).name}")
    private val inFormat = ex.getTrackFormat(trackIndex)
    private val codec: MediaCodec
    var sampleRate = inFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        private set
    var channels = inFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        private set
    private var inEos = false
    var eos = false
        private set
    private val info = MediaCodec.BufferInfo()
    private var pending: ShortArray = ShortArray(0)
    private var pendingPos = 0

    init {
        ex.selectTrack(trackIndex)
        if (startUs > 0) ex.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        codec = MediaCodec.createDecoderByType(inFormat.getString(MediaFormat.KEY_MIME)!!)
        codec.configure(inFormat, null, null, 0)
        codec.start()
    }

    /** Fills [dst] with interleaved samples; returns how many, 0 at the end. */
    fun read(dst: ShortArray): Int {
        var n = 0
        val start = System.nanoTime()
        while (n < dst.size) {
            if (pendingPos < pending.size) {
                val k = min(dst.size - n, pending.size - pendingPos)
                System.arraycopy(pending, pendingPos, dst, n, k)
                pendingPos += k
                n += k
                continue
            }
            if (eos) break
            check(System.nanoTime() - start < 15_000_000_000L) { "The audio decoder stopped responding" }
            if (!inEos) {
                val i = codec.dequeueInputBuffer(5_000)
                if (i >= 0) {
                    val buf = codec.getInputBuffer(i)!!
                    val sz = ex.readSampleData(buf, 0)
                    if (sz < 0) {
                        codec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inEos = true
                    } else {
                        codec.queueInputBuffer(i, 0, sz, ex.sampleTime, 0)
                        ex.advance()
                    }
                }
            }
            val o = codec.dequeueOutputBuffer(info, 5_000)
            if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                val f = codec.outputFormat
                sampleRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            } else if (o >= 0) {
                val buf = codec.getOutputBuffer(o)!!
                buf.position(info.offset)
                buf.limit(info.offset + info.size)
                val sb = buf.order(ByteOrder.nativeOrder()).asShortBuffer()
                pending = ShortArray(sb.remaining()).also { sb.get(it) }
                pendingPos = 0
                if (startUs > 0 && info.presentationTimeUs < startUs) {
                    // decoded from the sync point before the chosen start: drop the part before it
                    val skipFrames = ((startUs - info.presentationTimeUs) * sampleRate / 1_000_000L).toInt()
                    pendingPos = minOf(pending.size, skipFrames * channels)
                }
                codec.releaseOutputBuffer(o, false)
                if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) eos = true
            }
        }
        return n
    }

    /** Peeks the output format before reading (decodes the first chunk). */
    fun prime() {
        if (pending.isNotEmpty() || eos) return
        val tmp = ShortArray(1)
        val got = read(tmp)
        if (got == 1) {
            // put the sample back in front of what is pending
            val rest = pending.copyOfRange(pendingPos, pending.size)
            pending = ShortArray(rest.size + 1).also { it[0] = tmp[0]; System.arraycopy(rest, 0, it, 1, rest.size) }
            pendingPos = 0
        }
    }

    override fun close() {
        try { codec.stop() } catch (_: Exception) {}
        codec.release()
        ex.release()
    }
}

/** A PCM source at a fixed output rate and channel count (linear resampling, optional looping). */
internal class Stream(private val open: () -> PcmReader, private val outRate: Int, private val outCh: Int, private val loop: Boolean) : AutoCloseable {
    private var reader = open().also { it.prime() }
    private var inBuf = ShortArray(4096)
    private var inFrames = 0
    private var inPos = 0.0 // fractional frame position in inBuf
    private var ended = false

    private fun refill(): Boolean {
        var n = reader.read(inBuf)
        if (n == 0 && loop) {
            reader.close()
            reader = open().also { it.prime() }
            n = reader.read(inBuf)
        }
        inFrames = n / reader.channels
        return inFrames > 0
    }

    /** Writes [frames] interleaved float frames; silence after the end. */
    fun fill(out: FloatArray, frames: Int) {
        java.util.Arrays.fill(out, 0, frames * outCh, 0f)
        if (ended) return
        val step = reader.sampleRate.toDouble() / outRate
        val ch = reader.channels
        for (f in 0 until frames) {
            while (inPos >= inFrames) {
                inPos -= inFrames
                if (!refill()) {
                    ended = true
                    return
                }
            }
            val i0 = inPos.toInt()
            val t = (inPos - i0).toFloat()
            for (c in 0 until outCh) {
                val sc = if (ch == 1) 0 else min(c, ch - 1)
                val a = inBuf[i0 * ch + sc] / 32768f
                val b = if (i0 + 1 < inFrames) inBuf[(i0 + 1) * ch + sc] / 32768f else a
                out[f * outCh + c] = a + (b - a) * t
            }
            inPos += step
        }
    }

    override fun close() = reader.close()
}

/**
 * Mixes the video's own sound with background music into a new AAC track
 * (written to a temporary .m4a), so the exporter can copy it like any track.
 */
object AudioMixer {
    fun render(inputPath: String, voiceTrack: Int, durationUs: Long, mix: AudioMix, out: File) {
        val voice = if (voiceTrack >= 0) PcmReader(inputPath, voiceTrack).also { it.prime() } else null
        val rate = voice?.sampleRate?.takeIf { it in 8000..96000 } ?: 48000
        voice?.close()
        val ch = 2
        val voiceStream = if (voiceTrack >= 0) Stream({ PcmReader(inputPath, voiceTrack) }, rate, ch, loop = false) else null
        val musicStream = mix.musicPath?.let { p ->
            Stream({ PcmReader(p, null, mix.musicStartMs * 1000) }, rate, ch, loop = true)
        }

        val fmt = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, rate, ch).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, 192_000)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16 * 1024)
        }
        val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        enc.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        enc.start()
        val mux = MediaMuxer(out.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var track = -1
        var started = false
        val info = MediaCodec.BufferInfo()

        val totalFrames = durationUs * rate / 1_000_000L
        val chunk = 1024
        val v = FloatArray(chunk * ch)
        val m = FloatArray(chunk * ch)
        val pcm = ShortArray(chunk * ch)
        var env = 0f // voice loudness envelope
        var duck = 1f
        val attack = 1f - kotlin.math.exp(-1f / (0.01f * rate))
        val release = 1f - kotlin.math.exp(-1f / (0.35f * rate))
        val fadeIn = maxOf(1L, minOf((0.3f * rate).toLong(), totalFrames / 8))
        val fadeOut = maxOf(1L, minOf((1.5f * rate).toLong(), totalFrames / 4))
        var written = 0L
        var eosSent = false

        fun drain(wait: Boolean) {
            val t0 = System.nanoTime()
            while (true) {
                val o = enc.dequeueOutputBuffer(info, if (wait) 10_000 else 0)
                if (o == MediaCodec.INFO_TRY_AGAIN_LATER) {
                    if (!wait || System.nanoTime() - t0 > 15_000_000_000L) return
                    continue
                }
                if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    track = mux.addTrack(enc.outputFormat)
                    mux.start()
                    started = true
                    continue
                }
                if (o < 0) continue
                val buf = enc.getOutputBuffer(o)!!
                if (info.size > 0 && started && (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    mux.writeSampleData(track, buf, info)
                }
                enc.releaseOutputBuffer(o, false)
                if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) return
            }
        }

        try {
            val start = System.nanoTime()
            while (!eosSent) {
                check(System.nanoTime() - start < 600_000_000_000L) { "Audio mixing took too long" }
                val i = enc.dequeueInputBuffer(10_000)
                if (i < 0) { drain(false); continue }
                val frames = min(chunk.toLong(), totalFrames - written).toInt()
                if (frames <= 0) {
                    enc.queueInputBuffer(i, 0, 0, written * 1_000_000L / rate, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    eosSent = true
                    break
                }
                voiceStream?.fill(v, frames) ?: java.util.Arrays.fill(v, 0f)
                musicStream?.fill(m, frames) ?: java.util.Arrays.fill(m, 0f)
                for (f in 0 until frames) {
                    val pos = written + f
                    val vl = v[f * ch]
                    val vr = v[f * ch + 1]
                    val lvl = maxOf(abs(vl), abs(vr))
                    env += (lvl - env) * (if (lvl > env) attack else release)
                    if (mix.duck && musicStream != null) {
                        // talking -> music about 9 dB lower, eased in and out
                        val target = 1f - 0.65f * smooth(0.015f, 0.07f, env)
                        duck += (target - duck) * (if (target < duck) attack * 4 else release)
                    }
                    var g = mix.musicVolume * duck
                    if (pos < fadeIn) g *= pos.toFloat() / fadeIn
                    val left = totalFrames - pos
                    if (left < fadeOut) g *= left.toFloat() / fadeOut
                    for (c in 0 until ch) {
                        val x = v[f * ch + c] * mix.voiceVolume + m[f * ch + c] * g
                        pcm[f * ch + c] = (limit(x) * 32767f).toInt().toShort()
                    }
                }
                val buf = enc.getInputBuffer(i)!!
                buf.clear()
                buf.order(ByteOrder.nativeOrder()).asShortBuffer().put(pcm, 0, frames * ch)
                enc.queueInputBuffer(i, 0, frames * ch * 2, written * 1_000_000L / rate, 0)
                written += frames
                drain(false)
            }
            drain(true)
            check(started) { "No audio was produced" }
        } finally {
            try { enc.stop() } catch (_: Exception) {}
            enc.release()
            try { if (started) mux.stop() } catch (_: Exception) {}
            mux.release()
            voiceStream?.close()
            musicStream?.close()
        }
    }

    private fun smooth(a: Float, b: Float, x: Float): Float {
        val t = ((x - a) / (b - a)).coerceIn(0f, 1f)
        return t * t * (3 - 2 * t)
    }

    /** Transparent below 0.9, gentle saturation above (no hard clipping). */
    private fun limit(x: Float): Float {
        val a = abs(x)
        if (a <= 0.9f) return x
        val y = 0.9f + 0.1f * tanh((a - 0.9f) / 0.1f)
        return if (x < 0) -y else y
    }
}
