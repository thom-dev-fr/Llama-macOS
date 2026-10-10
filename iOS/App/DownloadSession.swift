import CryptoKit
import Foundation
import LlamaCore
import UserNotifications

/// The app's background download session. Model files keep transferring while
/// the app is suspended, and iOS relaunches the app to hand over the ones that
/// finished. Each file is checked against the SHA-256 Hugging Face advertises,
/// then placed in the HF cache.
///
/// Nothing here depends on the app's in-memory state, since a background
/// relaunch may deliver a file before any screen exists: each task names its
/// model and file in its description, and the download plan waits on disk next
/// to the model's placeholder. The library follows along through `onEvent`.
///
/// A stopped or failed transfer keeps its resume data on disk, so starting the
/// file again continues where it was. A model that finishes or fails is announced
/// with a notification, which iOS shows only while the app isn't on screen. Runs
/// on its delegate queue, off the main actor.
nonisolated final class DownloadSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  enum Event: Sendable {
    /// Bytes received so far by one file's transfer.
    case progress(modelId: String, url: URL, bytes: Int64)
    /// A file was verified and placed in the cache.
    case finished(modelId: String, url: URL, bytes: Int64)
    /// A file's transfer ended without it. `message` is nil when the transfer
    /// was cancelled, by the app or by the user force-quitting it.
    case stopped(modelId: String, url: URL, message: String?)
  }

  /// A file in flight, as the library sees it after a relaunch.
  struct Transfer: Sendable {
    let modelId: String
    let url: URL
    let bytes: Int64
  }

  static let shared = DownloadSession()
  static let identifier = "app.llama.ios.downloads"

  private let cacheDir = ModelLibrary.cacheDir
  private let lock = NSLock()
  private var session: URLSession!
  private var eventHandler: (@Sendable (Event) -> Void)?
  private var backgroundCompletion: (@MainActor @Sendable () -> Void)?
  /// Outcome of `didFinishDownloadingTo`, read back in `didCompleteWithError`.
  private var outcomes: [Int: Result<Int64, Error>] = [:]

  /// What a task carries in its description.
  private struct TaskInfo: Codable {
    let modelId: String
    let url: URL
  }

  private override init() {
    super.init()
    let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
    configuration.sessionSendsLaunchEvents = true
    configuration.isDiscretionary = false
    // Each request decides whether it may use cellular data.
    configuration.allowsCellularAccess = true
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
  }

  var onEvent: (@Sendable (Event) -> Void)? {
    get { lock.withLock { eventHandler } }
    set { lock.withLock { eventHandler = newValue } }
  }

  /// Called once iOS has delivered every event of a background relaunch.
  func setBackgroundCompletion(_ completion: @escaping @MainActor @Sendable () -> Void) {
    lock.withLock { backgroundCompletion = completion }
  }

  // MARK: - Plans

  /// Keeps the plan where a background relaunch can read it. It goes away with
  /// the model's partial dir once the download ends.
  func savePlan(_ plan: HFDownloadPlan, for modelId: String) throws {
    let url = planURL(for: modelId)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(plan).write(to: url, options: .atomic)
  }

  private func plan(for modelId: String) -> HFDownloadPlan? {
    guard let data = try? Data(contentsOf: planURL(for: modelId)) else { return nil }
    return try? JSONDecoder().decode(HFDownloadPlan.self, from: data)
  }

  private func planURL(for modelId: String) -> URL {
    HFCache.partialDir(cacheDir: cacheDir, modelId: modelId).appendingPathComponent(".plan.json")
  }

  // MARK: - Transfers

  /// Starts one file, continuing from its resume data when a previous transfer left some.
  func start(_ url: URL, of modelId: String, allowCellular: Bool, token: String?) {
    let resume = resumeURL(for: url, of: modelId)
    let task: URLSessionDownloadTask
    if let data = try? Data(contentsOf: resume) {
      // Consumed: if it no longer works, the task fails and the next start begins afresh.
      try? FileManager.default.removeItem(at: resume)
      task = session.downloadTask(withResumeData: data)
    } else {
      var request = HFRequest.make(url, token: token)
      request.allowsCellularAccess = allowCellular
      task = session.downloadTask(with: request)
    }
    task.taskDescription = (try? JSONEncoder().encode(TaskInfo(modelId: modelId, url: url)))
      .map { String(decoding: $0, as: UTF8.self) }
    task.resume()
  }

  /// Stops a model's transfers. With `keepingResumeData`, starting them again
  /// continues where they stopped. Returns once every task is cancelled.
  func stop(_ modelId: String, keepingResumeData: Bool) async {
    for task in await session.allTasks {
      guard let download = task as? URLSessionDownloadTask, info(of: task)?.modelId == modelId else { continue }
      if keepingResumeData {
        // The resume data also arrives with the cancellation error, which saves it.
        _ = await download.cancelByProducingResumeData()
      } else {
        download.cancel()
      }
    }
  }

  /// Forgets the resume data a model's files left behind.
  func discardResumeData(of model: Model) {
    for url in model.allDownloadUrls {
      try? FileManager.default.removeItem(at: resumeURL(for: url, of: model.id))
    }
  }

  /// Files in flight, including ones started before the app was relaunched.
  func transfers() async -> [Transfer] {
    await session.allTasks.compactMap { task in
      guard task.state == .running || task.state == .suspended, let info = info(of: task) else { return nil }
      return Transfer(modelId: info.modelId, url: info.url, bytes: task.countOfBytesReceived)
    }
  }

  private func info(of task: URLSessionTask) -> TaskInfo? {
    task.taskDescription.flatMap { try? JSONDecoder().decode(TaskInfo.self, from: Data($0.utf8)) }
  }

  private func resumeURL(for url: URL, of modelId: String) -> URL {
    let filename = HFCache.repoRelativePath(from: url) ?? url.lastPathComponent
    return HFCache.partialDir(cacheDir: cacheDir, modelId: modelId)
      .appendingPathComponent("\(filename).resume")
  }

  // MARK: - URLSessionDownloadDelegate

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                  didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                  totalBytesExpectedToWrite: Int64) {
    guard let info = info(of: downloadTask) else { return }
    onEvent?(.progress(modelId: info.modelId, url: info.url, bytes: totalBytesWritten))
  }

  // The file at `location` is deleted when this returns, so it is moved before anything else.
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                  didFinishDownloadingTo location: URL) {
    let outcome = Result { () throws -> Int64 in
      guard let info = info(of: downloadTask) else { throw failure("Unknown download.") }
      return try place(location, info: info, response: downloadTask.response)
    }
    lock.withLock { outcomes[downloadTask.taskIdentifier] = outcome }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let outcome = lock.withLock { outcomes.removeValue(forKey: task.taskIdentifier) }
    guard let info = info(of: task) else { return }
    if let error {
      let nsError = error as NSError
      if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
        let resume = resumeURL(for: info.url, of: info.modelId)
        try? FileManager.default.createDirectory(
          at: resume.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: resume, options: .atomic)
      }
      let cancelled = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
      stopped(info, message: cancelled ? nil : error.localizedDescription)
      return
    }
    switch outcome {
    case .success(let bytes):
      // Before the event: the library removes the placeholder once the model is complete.
      if let model = placeholder(of: info.modelId), model.missingFiles(cacheDir: cacheDir).isEmpty {
        notify(model.id, title: "\(model.displayName) is ready", body: "Start the engine to chat with it.")
      }
      onEvent?(.finished(modelId: info.modelId, url: info.url, bytes: bytes))
    case .failure(let failure):
      stopped(info, message: failure.localizedDescription)
    case nil:
      stopped(info, message: "The download ended without a file.")
    }
  }

  private func stopped(_ info: TaskInfo, message: String?) {
    if let message {
      let name = placeholder(of: info.modelId)?.displayName ?? info.modelId
      notify(info.modelId, title: "\(name) stopped downloading", body: message)
    }
    onEvent?(.stopped(modelId: info.modelId, url: info.url, message: message))
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    guard let completion = lock.withLock({ backgroundCompletion.take() }) else { return }
    Task { @MainActor in completion() }
  }

  // MARK: - Notifications

  /// Asks once whether downloads may notify. Call when the user starts one.
  static func requestNotifications() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  /// One notification per model: a later one replaces it, so files finishing
  /// together, or a failure stopping the others, still read as one.
  private func notify(_ modelId: String, title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: "download-\(modelId)", content: content, trigger: nil))
  }

  /// The model a download is for, from the placeholder saved when it started.
  private func placeholder(of modelId: String) -> Model? {
    let url = HFCache.placeholderURL(cacheDir: cacheDir, modelId: modelId)
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(Model.self, from: data)
  }

  // MARK: - Placing a file

  /// Verifies a downloaded file and moves it into the cache. Returns its size.
  private func place(_ location: URL, info: TaskInfo, response: URLResponse?) throws -> Int64 {
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200...299).contains(status) else {
      throw failure(HFRequest.failureMessage(forHTTPStatus: status))
    }
    guard let plan = plan(for: info.modelId) else {
      throw failure("The download lost track of its files. Discard it and start again.")
    }
    let filename = HFCache.repoRelativePath(from: info.url) ?? info.url.lastPathComponent
    let staging = HFCache.partialPath(cacheDir: cacheDir, modelId: info.modelId, filename: filename)
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fileManager.removeItem(at: staging)
    try fileManager.moveItem(at: location, to: staging)

    // An error page or an empty body, not a model file.
    let size = fileManager.fileSize(atPath: staging.path)
    guard size > 1_000_000 else {
      try? fileManager.removeItem(at: staging)
      throw failure("The download of \(info.url.lastPathComponent) was incomplete. Try again.")
    }
    var hasher = SHA256()
    try HFCache.feedHasher(&hasher, from: staging)
    let computed = HFCache.hex(hasher.finalize())
    if let expected = plan.blobHashes[info.url], expected != computed {
      try? fileManager.removeItem(at: staging)
      throw failure("\(info.url.lastPathComponent) failed verification. Try the download again.")
    }
    try HFCache.writeBlobAndLink(
      cacheDir: cacheDir, repoDir: plan.repoDir, commit: plan.commit,
      blobHash: plan.blobHashes[info.url] ?? computed, filename: filename, from: staging)
    return size
  }

  private func failure(_ message: String) -> NSError {
    NSError(domain: "DownloadSession", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}

nonisolated private extension Optional {
  /// Returns the value and leaves nil behind.
  mutating func take() -> Wrapped? {
    defer { self = nil }
    return self
  }
}
