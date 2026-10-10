import Foundation
import LlamaCore
import Observation

/// Runs the embedded server and mirrors its state for the UI. The only Swift code that
/// calls the C API in `MobileServer.h`.
///
/// The server runs while the app is in the foreground, with no model until one is
/// chosen. Going to the background stops it: that frees the model, which iOS would
/// otherwise count against a suspended app, and the listening socket, which iOS may
/// reclaim while the app is suspended. Coming back starts it again.
@Observable
final class EngineController {
  enum State: Equatable {
    case stopped
    case starting
    case running
    case stopping
  }

  private(set) var state = State.stopped
  /// Model held in memory. The WebUI swaps it on demand, so this follows the server.
  private(set) var loadedModel: String?
  var error: String?
  /// Fixed so the WebUI keeps its origin, and with it the IndexedDB chat history.
  static let port = 18080
  let url = URL(string: "http://127.0.0.1:\(port)")!
  private let queue = DispatchQueue(label: "app.llama.ios.engine", qos: .userInitiated)
  // The run occupies `queue` until shutdown. Presets must remain writable meanwhile.
  private let presetsQueue = DispatchQueue(label: "app.llama.ios.presets", qos: .userInitiated)
  private var presetsRevision = 0
  private(set) var isUpdatingPresets = false
  private var poll: Task<Void, Never>?
  /// Whether the app is in the foreground, where the server should run. A start asked
  /// for while a stop is still under way happens once the stop ends.
  private var wantsRunning = false
  /// The engine's log for the current run, like the Mac's `llama-server.log`. In
  /// Caches: it stays out of backups and is rewritten on every start.
  nonisolated static let logURL = FileManager.default
    .urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("llama-server.log")
  #if targetEnvironment(simulator)
  nonisolated private static let gpu = false
  #else
  nonisolated private static let gpu = true
  #endif

  /// The WebUI with `model` selected and loading, as the Mac's "Chat with model" opens it.
  func chatURL(model: String) -> URL {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    components.path = "/"
    components.queryItems = [
      URLQueryItem(name: "model", value: model),
      URLQueryItem(name: "load", value: "true"),
    ]
    return components.url!
  }

  /// Sets the models the WebUI can choose from: the sections of the `models.ini` at
  /// `url`. Applies to a running server too; a loaded model keeps its settings until
  /// it loads again.
  func setPresets(_ url: URL) {
    presetsRevision += 1
    isUpdatingPresets = true
    let revision = presetsRevision
    presetsQueue.async { [weak self] in
      var buffer = [CChar](repeating: 0, count: 512)
      let succeeded = mobile_server_set_presets(url.path, &buffer, buffer.count)
      let reason = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      Task { @MainActor [weak self] in
        guard let self, self.presetsRevision == revision else { return }
        self.isUpdatingPresets = false
        if !succeeded { self.error = "The model settings could not be read: \(reason)" }
      }
    }
  }

  /// Frees the loaded model, once the requests using it end. Not on `queue`: the run
  /// holds it until the server stops.
  func unload() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.global(qos: .userInitiated).async {
        mobile_server_unload()
        continuation.resume()
      }
    }
    refresh()
  }

  /// The app came to the foreground: runs the server, without a model.
  func activate() {
    wantsRunning = true
    start()
  }

  /// The app went to the background: stops the server, which frees the model.
  func deactivate() {
    wantsRunning = false
    stop()
  }

  /// Measures a model's memory at two context sizes, without loading it, the way the
  /// Mac does with `llama fit-params`. Nil when the measurement failed.
  nonisolated static func probeMemory(modelPath: String) async -> MemProfile? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        let (low, high) = MemProfile.probeContexts
        var lowBytes: UInt64 = 0
        var highBytes: UInt64 = 0
        guard mobile_server_probe_memory(modelPath, low, gpu, &lowBytes),
          mobile_server_probe_memory(modelPath, high, gpu, &highBytes)
        else { return continuation.resume(returning: nil) }
        continuation.resume(returning: MemProfile.fit(
          totalMibAtLow: Int(lowBytes >> 20), totalMibAtHigh: Int(highBytes >> 20)))
      }
    }
  }

  /// Starts the server with no model loaded; one is loaded when chosen. Also retries
  /// after a failed start.
  func start() {
    guard state == .stopped else { return }
    let gpu = Self.gpu
    error = nil
    state = .starting
    let port = Int32(Self.port)
    mobile_server_set_log_file(Self.logURL.path)
    // The run blocks until the server stops, so it gets its own queue, not a pool thread.
    queue.async {
      let result = mobile_server_run(nil, port, gpu)
      Task { @MainActor [weak self] in self?.didExit(result) }
    }
    poll = Task { [weak self] in
      while !Task.isCancelled {
        self?.refresh()
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }

  private func stop() {
    guard state == .starting || state == .running else { return }
    state = .stopping
    mobile_server_stop()
  }

  private func refresh() {
    // A stop can arrive before the C++ session exists, so repeat it until the run returns.
    if state == .stopping {
      mobile_server_stop()
      return
    }
    guard state != .stopped, mobile_server_ready() else { return }
    state = .running
    var buffer = [CChar](repeating: 0, count: 256)
    let length = mobile_server_loaded_model(&buffer, buffer.count)
    let name = length == 0 ? nil : String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    if name != loadedModel { loadedModel = name }
  }

  private func didExit(_ result: Int32) {
    poll?.cancel()
    poll = nil
    if result != 0 && state != .stopping {
      error = "The engine could not start (code \(result))."
    }
    state = .stopped
    loadedModel = nil
    // Back in the foreground while it was stopping.
    if wantsRunning && error == nil { start() }
  }
}
