package com.holistic.hbr_engine

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import android.util.Log
import java.io.File
import java.nio.ByteBuffer
import kotlin.math.roundToInt

/** How long a codec may go without making progress before we give up. */
private const val STALL_NS = 15_000_000_000L

class ExportCancelled : Exception("cancelled")

class NoPersonFound : Exception(
    "No person was detected in this video, so the background could not be replaced. " +
        "Use a video where a person is clearly visible.",
)

/**
 * Full-quality export:
 *  - decode every frame at full resolution (hardware decoder)
 *  - segment the person, refine the matte at full resolution, composite in Y'CbCr
 *  - encode with the source codec family, size, timestamps, colour tags and
 *    at least the source bitrate (hardware encoder)
 *  - copy the audio track bit-for-bit (no re-encode)
 *  - keep the rotation as metadata, like the camera wrote it
 */
class Exporter(
    private val context: Context,
    private val inputPath: String,
    private val outputPath: String,
    private val background: Map<*, *>,
    private val settings: Map<*, *>,
    private val onProgress: (fraction: Double, frames: Int, fps: Double) -> Unit,
    private val isCancelled: () -> Boolean,
) {
    private val info = MediaCodec.BufferInfo()
    private var muxer: MediaMuxer? = null
    private var muxerStarted = false
    private var videoTrack = -1
    private var audio: AudioCopier? = null
    private var mixedAudio: File? = null

    /** Returns a warning to show the user, or null. */
    fun run(): String? {
        var warning: String? = null
        val decoder = FrameDecoder(inputPath)
        val meta = decoder.meta
        val w = decoder.width
        val h = decoder.height
        val temporal = (settings["temporalStrength"] as? Number)?.toFloat() ?: 0.45f
        val softness = (settings["edgeSoftness"] as? Number)?.toFloat() ?: 0.2f
        val smoothing = (settings["edgeSmoothing"] as? Number)?.toFloat() ?: 0.8f
        val clean = settings["cleanEdges"] as? Boolean ?: true
        var encoder: MediaCodec? = null
        val outFile = File(outputPath)
        try {
            val layout = Layout.from(settings, w, h, meta.rotation)
            val cw = layout.canvasW
            val ch = layout.canvasH
            MatteEngine(w, h, temporal, softness, smoothing, clean).use { engine ->
                val compositor = Compositor(engine, layout, meta.matrix, meta.fullRange)
                val sideways = meta.rotation % 180 != 0
                val captions = CaptionRenderer.from(
                    settings, if (sideways) ch else cw, if (sideways) cw else ch, meta.rotation, meta.matrix, meta.fullRange,
                )
                BackgroundSource.create(background, cw, ch, meta.rotation, meta.matrix, meta.fullRange).use { bg ->
                    Segmenter(context, meta.displayWidth > meta.displayHeight, video = true).use { seg ->
                        encoder = createEncoder(meta, cw, ch)
                        val enc = encoder!!
                        enc.start()
                        val mux = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                        muxer = mux
                        mux.setOrientationHint(meta.rotation)
                        val mix = AudioMix.from(settings)
                        if (!mix.passthrough) {
                            // music and/or voice level: mix into a new AAC track first
                            try {
                                val f = File(context.cacheDir, "hbr_mix_${System.nanoTime()}.m4a")
                                mixedAudio = f
                                AudioMixer.render(inputPath, meta.audioTrack, meta.durationUs, mix, f)
                                audio = AudioCopier(f.path, 0)
                            } catch (e: Exception) {
                                Log.w("HbrEngine", "audio mix failed", e)
                                warning = "The music could not be added (${e.message}); the original sound was kept."
                            }
                        }
                        if (audio == null && meta.audioTrack >= 0) {
                            audio = try {
                                AudioCopier(inputPath, meta.audioTrack).also { c ->
                                    if (!AudioCopier.muxable(c.format, context.cacheDir)) {
                                        c.close()
                                        throw IllegalStateException("format ${c.format.getString(MediaFormat.KEY_MIME)} cannot be copied")
                                    }
                                }
                            } catch (e: Exception) {
                                Log.w("HbrEngine", "audio copy not possible, re-encoding", e)
                                null
                            }
                            if (audio == null) {
                                // the sound cannot be copied as it is: re-encode it (AAC 192k) so it is never lost
                                try {
                                    val f = File(context.cacheDir, "hbr_mix_${System.nanoTime()}.m4a")
                                    mixedAudio = f
                                    AudioMixer.render(inputPath, meta.audioTrack, meta.durationUs, AudioMix(null), f)
                                    audio = AudioCopier(f.path, 0)
                                } catch (e: Exception) {
                                    Log.w("HbrEngine", "audio re-encode failed", e)
                                    warning = "The sound could not be kept: ${e.message}"
                                }
                            }
                        }

                        val totalUs = meta.durationUs.coerceAtLeast(1)
                        val started = System.nanoTime()
                        var frames = 0
                        var firstPts = -1L
                        var personFrames = 0
                        while (decoder.next()) {
                            if (isCancelled()) throw ExportCancelled()
                            val pts = decoder.ptsUs
                            if (firstPts < 0) firstPts = pts
                            val mask = seg.segment(decoder.frame, meta.rotation, meta.matrix, meta.fullRange, pts)
                            if (mask.coverage() > 0.005f) personFrames++
                            engine.refine(decoder.frame, mask.buffer, mask.width, mask.height, meta.rotation)
                            val bgFrame = bg.next()

                            val inIdx = dequeueInput(enc)
                            val img = enc.getInputImage(inIdx) ?: error("Encoder has no image input")
                            val p = img.planes
                            compositor.compose(
                                decoder.frame, bgFrame, p[0].buffer, p[0].rowStride, p[1].buffer, p[2].buffer,
                                p[1].rowStride, p[1].pixelStride,
                            )
                            captions?.draw(
                                (pts - firstPts) / 1000, p[0].buffer, p[0].rowStride, p[1].buffer, p[2].buffer,
                                p[1].rowStride, p[1].pixelStride, cw, ch,
                            )
                            enc.queueInputBuffer(inIdx, 0, HbrNative.i420Size(cw, ch), pts, 0)
                            drain(enc, false)

                            frames++
                            if (frames % 5 == 0) {
                                val secs = (System.nanoTime() - started) / 1e9
                                onProgress(((pts - firstPts).toDouble() / totalUs).coerceIn(0.0, 0.99), frames, frames / secs)
                            }
                        }
                        // end of stream
                        val inIdx = dequeueInput(enc)
                        enc.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        drain(enc, true)
                        check(muxerStarted && frames > 0) { "No frames were encoded" }
                        // Never hand back a video that is only the new background.
                        if (personFrames == 0) throw NoPersonFound()
                        Log.i("HbrEngine", "Person found in $personFrames of $frames frames")
                        audio?.copyUntil(mux, Long.MAX_VALUE)
                        val secs = (System.nanoTime() - started) / 1e9
                        onProgress(1.0, frames, frames / secs)
                    }
                }
            }
            muxer?.stop()
            if (meta.isHdr) {
                warning = listOfNotNull(warning, "HDR video was processed in 8-bit; colours keep their HDR tags.").joinToString(" ")
            }
            return warning
        } catch (e: Throwable) {
            outFile.delete()
            throw e
        } finally {
            try { encoder?.stop() } catch (_: Exception) {}
            encoder?.release()
            try { muxer?.release() } catch (_: Exception) {}
            audio?.close()
            mixedAudio?.delete()
            decoder.close()
        }
    }

    private fun dequeueInput(enc: MediaCodec): Int {
        val start = System.nanoTime()
        while (true) {
            val idx = enc.dequeueInputBuffer(10_000)
            if (idx >= 0) return idx
            drain(enc, false)
            check(System.nanoTime() - start < STALL_NS) { "The video encoder stopped responding" }
        }
    }

    private fun drain(enc: MediaCodec, endOfStream: Boolean) {
        var idleSince = System.nanoTime()
        while (true) {
            val idx = enc.dequeueOutputBuffer(info, if (endOfStream) 10_000 else 0)
            if (idx != MediaCodec.INFO_TRY_AGAIN_LATER) idleSince = System.nanoTime()
            when {
                idx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream) return
                    // Some encoders never flag the last buffer; don't wait forever.
                    if (System.nanoTime() - idleSince > STALL_NS) {
                        Log.w("HbrEngine", "Encoder did not signal end of stream; finishing")
                        return
                    }
                }
                idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val mux = muxer!!
                    check(!muxerStarted) { "Encoder format changed twice" }
                    videoTrack = mux.addTrack(enc.outputFormat)
                    audio?.let { a ->
                        try {
                            a.track = mux.addTrack(a.format)
                        } catch (e: Exception) {
                            Log.w("HbrEngine", "Audio format not supported by muxer", e)
                            a.close()
                            audio = null
                        }
                    }
                    mux.start()
                    muxerStarted = true
                }
                idx >= 0 -> {
                    val buf = enc.getOutputBuffer(idx)!!
                    val isConfig = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                    if (info.size > 0 && !isConfig && muxerStarted) {
                        buf.position(info.offset)
                        buf.limit(info.offset + info.size)
                        muxer!!.writeSampleData(videoTrack, buf, info)
                        // interleave audio up to the video we have written
                        audio?.copyUntil(muxer!!, info.presentationTimeUs)
                    }
                    enc.releaseOutputBuffer(idx, false)
                    if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) return
                }
            }
        }
    }

    private fun createEncoder(meta: VideoMeta, w: Int, h: Int): MediaCodec {
        // Same codec family as the source when the phone can encode it.
        val candidates = buildList {
            if (meta.mime == MediaFormat.MIMETYPE_VIDEO_HEVC) add(MediaFormat.MIMETYPE_VIDEO_HEVC)
            add(MediaFormat.MIMETYPE_VIDEO_AVC)
            if (meta.mime != MediaFormat.MIMETYPE_VIDEO_HEVC) add(MediaFormat.MIMETYPE_VIDEO_HEVC)
        }
        val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
        var lastError: Exception? = null
        for (mime in candidates) {
            for (withProfile in listOf(true, false)) {
                val fmt = encoderFormat(meta, mime, w, h, withProfile) ?: continue
                val name = list.findEncoderForFormat(fmt) ?: continue
                try {
                    val codec = MediaCodec.createByCodecName(name)
                    try {
                        codec.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                        Log.i("HbrEngine", "Encoder $name $mime ${w}x$h $fmt")
                        return codec
                    } catch (e: Exception) {
                        codec.release()
                        throw e
                    }
                } catch (e: Exception) {
                    lastError = e
                }
            }
        }
        throw IllegalStateException("This phone has no encoder for ${w}x$h video", lastError)
    }

    private fun encoderFormat(meta: VideoMeta, mime: String, w: Int, h: Int, withProfile: Boolean): MediaFormat? {
        val caps = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            .filter { it.isEncoder && it.supportedTypes.any { t -> t.equals(mime, true) } }
            .map { it.getCapabilitiesForType(mime) }
            .firstOrNull { it.videoCapabilities?.isSizeSupported(w, h) == true } ?: return null
        val fps = meta.frameRate.coerceIn(1f, 240f)
        // Never go below the source bitrate; small floor for very low bitrate
        // sources so re-encoding does not add visible artefacts.
        val floor = (w * h * fps * if (mime == MediaFormat.MIMETYPE_VIDEO_HEVC) 0.07f else 0.1f).toInt()
        val target = maxOf(meta.bitrate, floor)
        val bitrate = caps.videoCapabilities!!.bitrateRange.clamp(target)
        return MediaFormat.createVideoFormat(mime, w, h).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps.roundToInt())
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            val enc = caps.encoderCapabilities
            if (enc?.isBitrateModeSupported(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR) == true) {
                setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
            }
            meta.colorStandard?.let { setInteger(MediaFormat.KEY_COLOR_STANDARD, it) }
            meta.colorRange?.let { setInteger(MediaFormat.KEY_COLOR_RANGE, it) }
            meta.colorTransfer?.let { setInteger(MediaFormat.KEY_COLOR_TRANSFER, it) }
            if (withProfile) {
                val wanted = when (mime) {
                    MediaFormat.MIMETYPE_VIDEO_AVC -> MediaCodecInfo.CodecProfileLevel.AVCProfileHigh
                    MediaFormat.MIMETYPE_VIDEO_HEVC -> MediaCodecInfo.CodecProfileLevel.HEVCProfileMain
                    else -> null
                }
                val pl = caps.profileLevels.filter { it.profile == wanted }.maxByOrNull { it.level }
                if (pl == null) return null
                setInteger(MediaFormat.KEY_PROFILE, pl.profile)
                if (Build.VERSION.SDK_INT >= 23) setInteger(MediaFormat.KEY_LEVEL, pl.level)
            }
        }
    }
}

/** Copies the original audio samples into the output without re-encoding. */
class AudioCopier(path: String, trackIndex: Int) : AutoCloseable {
    private val extractor = MediaExtractor()
    val format: MediaFormat
    var track = -1
    private val buffer: ByteBuffer
    private val info = MediaCodec.BufferInfo()
    private var done = false

    init {
        extractor.setDataSource(path)
        extractor.selectTrack(trackIndex)
        format = extractor.getTrackFormat(trackIndex)
        val max = format.intOr(MediaFormat.KEY_MAX_INPUT_SIZE) ?: (512 * 1024)
        buffer = ByteBuffer.allocateDirect(maxOf(max, 64 * 1024))
    }

    fun copyUntil(muxer: MediaMuxer, ptsUs: Long) {
        if (track < 0) return
        while (!done) {
            if (extractor.sampleTrackIndex < 0) {
                done = true
                return
            }
            val t = extractor.sampleTime
            if (t < 0) {
                // encoder priming before time zero (edit list): not audible, skip it
                extractor.advance()
                continue
            }
            if (t > ptsUs) return
            buffer.clear()
            val n = extractor.readSampleData(buffer, 0)
            if (n < 0) {
                done = true
                return
            }
            var flags = 0
            if ((extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC) != 0) flags = flags or MediaCodec.BUFFER_FLAG_KEY_FRAME
            info.set(0, n, t, flags)
            muxer.writeSampleData(track, buffer, info)
            extractor.advance()
        }
    }

    override fun close() = extractor.release()

    companion object {
        /** True when MediaMuxer accepts this track format as it is. */
        fun muxable(format: MediaFormat, dir: File): Boolean {
            val f = File(dir, "hbr_probe_${System.nanoTime()}.mp4")
            var m: MediaMuxer? = null
            return try {
                m = MediaMuxer(f.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                m.addTrack(format)
                true
            } catch (e: Exception) {
                Log.w("HbrEngine", "muxer rejects audio format $format", e)
                false
            } finally {
                try { m?.release() } catch (_: Exception) {}
                f.delete()
            }
        }
    }
}
