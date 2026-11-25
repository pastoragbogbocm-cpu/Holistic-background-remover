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
    private val main = Handler(Looper.getMainLooper())
    private val exportExecutor = Executors.newSingleThreadExecutor()
    private val previewExecutor = Executors.newSingleThreadExecutor()
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
            "probe" -> previewExecutor.execute {
                runCatching { VideoProbe.probe(call.argument<String>("path")!!).toMap() }
                    .fold({ m -> main.post { result.success(m) } },
                        { e -> main.post { result.error("probe_failed", e.message, null) } })
            }
            "preview" -> previewExecutor.execute {
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
