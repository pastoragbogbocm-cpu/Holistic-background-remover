package com.holistic.hbr_engine

import android.graphics.ImageFormat
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat

/**
 * Pull-style hardware decoder: each [next] call yields one frame as a tight
 * 8-bit I420 buffer at full source resolution, in storage orientation.
 * With [loop] the video restarts when it ends (used for video backgrounds).
 */
class FrameDecoder(path: String, private val loop: Boolean = false) : AutoCloseable {
    private val extractor = MediaExtractor()
    private val decoder: MediaCodec
    private val info = MediaCodec.BufferInfo()
    val meta: VideoMeta = VideoProbe.probe(path)
    val width: Int
    val height: Int
    val frame: I420Frame

    /** Presentation time of the current frame (monotonic, also across loops). */
    var ptsUs: Long = 0
        private set

    private var inputEos = false
    private var outputEos = false
    private var loopOffsetUs = 0L
    private var lastRawPtsUs = 0L
    private var framesInPass = 0

    init {
        extractor.setDataSource(path)
        extractor.selectTrack(meta.videoTrack)
        val format = extractor.getTrackFormat(meta.videoTrack)
        val size = VideoProbe.visibleSize(format)
        width = size.first
        height = size.second
        frame = I420Frame(width, height)
        val mime = format.getString(MediaFormat.KEY_MIME)!!
        format.setInteger(
            MediaFormat.KEY_COLOR_FORMAT,
            MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible,
        )
        decoder = MediaCodec.createDecoderByType(mime)
        decoder.configure(format, null, null, 0)
        decoder.start()
    }

    /** Decodes the next frame into [frame]. Returns false at end of stream. */
    fun next(): Boolean {
        while (true) {
            if (outputEos) {
                if (!loop || framesInPass == 0) return false
                restart()
            }
            if (!inputEos) feedInput()
            val idx = decoder.dequeueOutputBuffer(info, 10_000)
            if (idx < 0) continue // try-again / format change: keep pumping
            val eos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
            var produced = false
            if (info.size > 0) {
                val image = decoder.getOutputImage(idx)
                if (image != null) {
                    image.use { img ->
                        val p = img.planes
                        val crop = img.cropRect
                        val bytesPerSample = if (img.format == ImageFormat.YUV_420_888) 1 else 2
                        val rc = HbrNative.nativeCopyToI420(
                            p[0].buffer, p[0].rowStride, p[0].pixelStride,
                            p[1].buffer, p[2].buffer, p[1].rowStride, p[1].pixelStride,
                            bytesPerSample, crop.left, crop.top,
                            minOf(width, crop.width()), minOf(height, crop.height()), frame.buffer,
                        )
                        check(rc == 0) { "Unsupported decoder output layout (format ${img.format})" }
                    }
                    lastRawPtsUs = info.presentationTimeUs
                    ptsUs = loopOffsetUs + info.presentationTimeUs
                    framesInPass++
                    produced = true
                }
            }
            decoder.releaseOutputBuffer(idx, false)
            if (eos) outputEos = true
            if (produced) return true
        }
    }

    private fun feedInput() {
        val idx = decoder.dequeueInputBuffer(10_000)
        if (idx < 0) return
        val buf = decoder.getInputBuffer(idx)!!
        val n = extractor.readSampleData(buf, 0)
        if (n < 0) {
            decoder.queueInputBuffer(idx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            inputEos = true
        } else {
            decoder.queueInputBuffer(idx, 0, n, extractor.sampleTime, 0)
            extractor.advance()
        }
    }

    private fun restart() {
        val frameDur = (1_000_000 / meta.frameRate.coerceAtLeast(1f)).toLong()
        loopOffsetUs += lastRawPtsUs + frameDur
        extractor.seekTo(0, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
        decoder.flush()
        inputEos = false
        outputEos = false
        framesInPass = 0
    }

    override fun close() {
        try { decoder.stop() } catch (_: Exception) {}
        decoder.release()
        extractor.release()
    }
}
