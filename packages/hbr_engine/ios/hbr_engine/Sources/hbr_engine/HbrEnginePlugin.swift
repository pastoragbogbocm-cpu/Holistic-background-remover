import Flutter
import UIKit

/// Flutter bridge: method channel `hbr_engine`, event channel `hbr_engine/progress`.
public class HbrEnginePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  private let previewQueue = DispatchQueue(label: "hbr.preview", qos: .userInitiated)
  private let previewer = FramePreviewer()
  private let cancelLock = NSLock()
  private var cancelled = false

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = HbrEnginePlugin()
    let channel = FlutterMethodChannel(name: "hbr_engine", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
    let events = FlutterEventChannel(name: "hbr_engine/progress", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private func emit(_ map: [String: Any?]) {
    DispatchQueue.main.async { self.sink?(map.compactMapValues { $0 }) }
  }

  private var isCancelled: Bool {
    cancelLock.lock()
    defer { cancelLock.unlock() }
    return cancelled
  }

  private func setCancelled(_ v: Bool) {
    cancelLock.lock()
    cancelled = v
    cancelLock.unlock()
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "probe":
      guard let path = args["path"] as? String else { return result(badArgs()) }
      Task {
        do {
          let meta = try await VideoMeta.load(path: path)
          let map = meta.toMap()
          DispatchQueue.main.async { result(map) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "probe_failed", message: error.localizedDescription, details: nil))
          }
        }
      }

    case "preview":
      guard let path = args["path"] as? String, let bg = args["background"] as? [String: Any] else {
        return result(badArgs())
      }
      let timeMs = (args["timeMs"] as? NSNumber)?.intValue ?? 0
      let settings = args["settings"] as? [String: Any] ?? [:]
      let maxSize = (args["maxSize"] as? NSNumber)?.intValue ?? 960
      previewQueue.async {
        do {
          let jpeg = try self.previewer.render(path: path, timeMs: timeMs, background: bg,
                                               settings: settings, maxSize: maxSize)
          DispatchQueue.main.async { result(FlutterStandardTypedData(bytes: jpeg)) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "preview_failed", message: error.localizedDescription, details: nil))
          }
        }
      }

    case "export":
      guard let jobId = args["jobId"] as? String, let input = args["input"] as? String,
            let output = args["output"] as? String, let bg = args["background"] as? [String: Any] else {
        return result(badArgs())
      }
      let settings = args["settings"] as? [String: Any] ?? [:]
      setCancelled(false)
      result(nil)
      Task.detached(priority: .userInitiated) {
        // Keep the export running if the user switches apps briefly.
        let bgTask = await UIApplication.shared.beginBackgroundTask(withName: "hbr.export")
        defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(bgTask) } }
        let exporter = VideoExporter(
          inputPath: input, outputPath: output, background: bg, settings: settings,
          progress: { [weak self] f, frames, fps in
            self?.emit(["jobId": jobId, "fraction": f, "frames": frames, "fps": fps])
          },
          isCancelled: { [weak self] in self?.isCancelled ?? true })
        do {
          let (path, warning) = try await exporter.run()
          self.emit(["jobId": jobId, "fraction": 1.0, "done": true, "outputPath": path, "warning": warning])
        } catch is ExportCancelled {
          self.emit(["jobId": jobId, "cancelled": true])
        } catch {
          self.emit(["jobId": jobId, "error": error.localizedDescription])
        }
      }

    case "cancel":
      setCancelled(true)
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func badArgs() -> FlutterError {
    FlutterError(code: "bad_args", message: "Missing arguments", details: nil)
  }
}
