package com.holistic.hbr_engine

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Flutter bridge: method channel `hbr_engine`, event channel `hbr_engine/progress`. */
class HbrEnginePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var channel: MethodChannel
    private lateinit var events: EventChannel
    private lateinit var context: Context
    // Asynchronous messages, like Flutter's own platform queue: results are
    // delivered even while the window holds a layout barrier on the main queue.
    private val main: Handler =
        if (android.os.Build.VERSION.SDK_INT >= 28) Handler.createAsync(Looper.getMainLooper())
        else Handler(Looper.getMainLooper())
    private val exportExecutor = Executors.newSingleThreadExecutor()
    // Preview work runs at background priority so the screen always stays responsive.
    private val previewExecutor = Executors.newSingleThreadExecutor { r ->
        Thread({
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND)
            r.run()
        }, "hbr-preview")
    }
    /** Only the newest preview request is rendered; older queued ones are skipped. */
    private val previewGen = java.util.concurrent.atomic.AtomicLong()
    private val speechExecutor = Executors.newSingleThreadExecutor()
    private val speechCancel = AtomicBoolean(false)
    private var transcriber: Transcriber? = null
    private var sink: EventChannel.EventSink? = null
    private val cancelFlag = AtomicBoolean(false)
    private var previewer: Previewer? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "hbr_engine")
        channel.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, "hbr_engine/progress")
        events.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        events.setStreamHandler(null)
        cancelFlag.set(true)
        previewExecutor.execute { previewer?.close(); previewer = null }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun emit(map: Map<String, Any?>) = main.post { sink?.success(map) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "transcribe" -> {
                speechCancel.set(false)
                val jobId = call.argument<String>("jobId")!!
                speechExecutor.execute {
                    try {
                        val path = call.argument<String>("path")!!
                        val meta = VideoProbe.probe(path)
                        emit(mapOf("jobId" to jobId, "fraction" to 0.02, "stage" to "audio"))
                        val pcm = Transcriber.loadAudio(path, meta.audioTrack, meta.durationUs)
                        val t = transcriber ?: Transcriber.open(context).also { transcriber = it }
                        val json = t.transcribe(pcm, call.argument<String>("language") ?: "en") { pct ->
                            emit(mapOf("jobId" to jobId, "fraction" to 0.05 + 0.95 * pct / 100.0, "stage" to "speech"))
                            speechCancel.get()
                        }
                        main.post {
                            if (json == null) result.error("cancelled", "cancelled", null) else result.success(json)
                        }
                    } catch (e: Throwable) {
                        Log.e("HbrEngine", "transcribe failed", e)
                        main.post { result.error("transcribe_failed", e.message ?: e.javaClass.simpleName, null) }
                    }
                }
            }
            "cancelTranscribe" -> {
                speechCancel.set(true)
                result.success(null)
            }
            "probe" -> previewExecutor.execute {
                runCatching { VideoProbe.probe(call.argument<String>("path")!!).toMap() }
                    .fold({ m -> main.post { result.success(m) } },
                        { e -> main.post { result.error("probe_failed", e.message, null) } })
            }
            "preview" -> {
              val gen = previewGen.incrementAndGet()
              previewExecutor.execute {
                if (gen != previewGen.get()) {
                    main.post { result.success(null) } // superseded by a newer request
                    return@execute
                }
                runCatching {
                    val p = previewer ?: Previewer(context).also { previewer = it }
                    p.render(
                        call.argument<String>("path")!!,
                        (call.argument<Number>("timeMs") ?: 0).toLong(),
                        call.argument<Map<*, *>>("background")!!,
                        call.argument<Map<*, *>>("settings") ?: emptyMap<String, Any>(),
                        call.argument<Int>("maxSize") ?: 960,
                    )
                }.fold({ b -> main.post { result.success(b) } },
                    { e ->
                        Log.e("HbrEngine", "preview failed", e)
                        main.post { result.error("preview_failed", e.message, null) }
                    })
              }
            }
            "export" -> {
                val jobId = call.argument<String>("jobId")!!
                cancelFlag.set(false)
                result.success(null)
                exportExecutor.execute { runExport(jobId, call) }
            }
            "cancel" -> {
                cancelFlag.set(true)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun runExport(jobId: String, call: MethodCall) {
        val output = call.argument<String>("output")!!
        try {
            val warning = Exporter(
                context,
                call.argument<String>("input")!!,
                output,
                call.argument<Map<*, *>>("background")!!,
                call.argument<Map<*, *>>("settings") ?: emptyMap<String, Any>(),
                onProgress = { f, frames, fps ->
                    emit(mapOf("jobId" to jobId, "fraction" to f, "frames" to frames, "fps" to fps))
                },
                isCancelled = { cancelFlag.get() },
            ).run()
            emit(mapOf("jobId" to jobId, "fraction" to 1.0, "done" to true, "outputPath" to output, "error" to null,
                "warning" to warning))
        } catch (e: ExportCancelled) {
            emit(mapOf("jobId" to jobId, "cancelled" to true))
        } catch (e: Throwable) {
            Log.e("HbrEngine", "export failed", e)
            emit(mapOf("jobId" to jobId, "error" to (e.message ?: e.javaClass.simpleName)))
        }
    }
}
