import Foundation
import LlamaCore
import Observation

/// The models on this device, kept in a Hugging Face cache inside the app's
/// container, and the ways to add more: catalog recommendations, a Hugging Face
/// repo, or a `llama://install` link. Downloads run in `DownloadSession`, which
/// keeps them going in the background; the library follows its events.
@Observable
final class ModelLibrary {
  /// A model downloading now.
  struct Download {
    let model: Model
    /// Bytes of the files already in the cache.
    var finishedBytes: Int64
    /// Bytes received by each file in flight.
    var inFlight: [URL: Int64] = [:]
    /// Why a file failed, reported once the model's other files have stopped.
    var failure: String?

    var bytes: Int64 { finishedBytes + inFlight.values.reduce(0, +) }
    var fraction: Double { model.fileSize > 0 ? min(Double(bytes) / Double(model.fileSize), 1) : 0 }
  }

  /// The HF cache models live in, inside the app container. Shared with
  /// `DownloadSession`, which places files there even before the library exists.
  nonisolated static let cacheDir = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("huggingface/hub", isDirectory: true)

  private(set) var installed: [Model] = []
  private(set) var paths: [String: ResolvedPaths] = [:]
  /// Downloads stopped before the end, in this session or an earlier one.
  /// Their finished files stay in the cache, so starting again picks up there.
  private(set) var interrupted: [Model] = []
  private(set) var suggestions: [Catalog.Suggestion] = []
  /// Where the recommendations stand. A reload keeps the last list in view: only a
  /// first load, or a retry after a failure, shows progress in its place.
  enum SuggestionsState: Equatable {
    case loading
    case loaded
    case failed(String)
  }
  private(set) var suggestionsState = SuggestionsState.loading
  /// In start order.
  private(set) var downloads: [Download] = []
  /// Applies to downloads started from now on.
  var allowCellular = UserDefaults.standard.bool(forKey: ModelLibrary.allowCellularKey) {
    didSet { UserDefaults.standard.set(allowCellular, forKey: Self.allowCellularKey) }
  }
  var error: String?
  /// The engine's model list: one `models.ini` section per installed model, generated
  /// like the Mac's. `presetRevision` changes each time the file is rewritten.
  let presetsURL = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("models.ini")
  private(set) var presetRevision = 0
  /// Models with a section in `models.ini`, which the engine can load.
  private(set) var loadableModels: [String] = []
  let cacheDir = ModelLibrary.cacheDir
  private let session = DownloadSession.shared
  private static let allowCellularKey = "allowCellular"
  private static let contextTiersKey = "contextTiers"
  /// Context size chosen per model id, in tokens. Kept here rather than read from
  /// `UserDefaults` on demand so that views showing it update when it changes.
  private var chosenContexts = UserDefaults.standard.dictionary(forKey: ModelLibrary.contextTiersKey)
    as? [String: Int] ?? [:] {
    didSet { UserDefaults.standard.set(chosenContexts, forKey: Self.contextTiersKey) }
  }
  /// Whether a Hugging Face token is saved. The token itself stays in the Keychain.
  private(set) var hasToken = Keychain.huggingFaceToken != nil
  /// Sent to Hugging Face, which needs it for gated and private repos.
  private var token: String? { Keychain.huggingFaceToken }
  /// Models whose memory is being measured.
  private var probing: Set<String> = []
  private var suggestionsTask: Task<Void, Never>?
  private var startupTask: Task<Void, Never>?
  private(set) var isLoading = true
  private var startupEvents: [DownloadSession.Event] = []
  private var scanRevision = 0

  init() {
    session.onEvent = { [weak self] event in
      Task { @MainActor in self?.receive(event) }
    }
    let cacheDir = cacheDir
    startupTask = Task {
      let (scan, failure) = await Self.initialScan(cacheDir: cacheDir)
      if let failure { error = failure }
      apply(scan)
      await restoreDownloads()
      isLoading = false
      startupTask = nil
      let events = startupEvents
      startupEvents.removeAll()
      for event in events { handle(event) }
      // A transfer can finish between the disk scan and the session snapshot.
      if !events.isEmpty { refresh() }
    }
  }

  @concurrent
  private static func initialScan(cacheDir: URL) async -> (CacheScan, String?) {
    var failure: String?
    do {
      try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
      // Models can be downloaded again, so they stay out of device backups.
      var directory = cacheDir
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try directory.setResourceValues(values)
    } catch {
      failure = error.localizedDescription
    }
    return (CacheScan(cacheDir: cacheDir), failure)
  }

  /// Recommendations whose repo has no installed model yet.
  var visibleSuggestions: [Catalog.Suggestion] {
    let installedBases = Set(installed.map(\.idBase))
    return suggestions.filter { !installedBases.contains(Model.idBase(orgSlashRepo: $0.repo)) }
  }

  /// Fetches the recommendations. A load already running is joined rather than
  /// doubled, as when a pull to refresh lands during the first one.
  func loadSuggestions() async {
    if let suggestionsTask { return await suggestionsTask.value }
    let task = Task {
      if suggestions.isEmpty { suggestionsState = .loading }
      do {
        suggestions = try await Catalog.featured(
          systemMemoryMb: DeviceMemory.physicalMb, budgetMb: DeviceMemory.budgetMb)
        suggestionsState = .loaded
      } catch {
        suggestionsState = .failed(error.localizedDescription)
      }
    }
    suggestionsTask = task
    await task.value
    suggestionsTask = nil
  }

  func refresh() {
    let cacheDir = cacheDir
    Task {
      await startupTask?.value
      scanRevision += 1
      let revision = scanRevision
      let scan = await Task.detached { CacheScan(cacheDir: cacheDir) }.value
      guard revision == scanRevision else { return }
      apply(scan)
    }
  }

  /// Picks the files to download for a repo, and a quant that fits this device
  /// unless `quant` names one.
  func resolve(repo: String, quant: String?) async throws -> Model {
    await startupTask?.value
    let resolved = try await HFRepoResolver.resolve(
      repo: repo, quant: quant, token: token, budgetMb: DeviceMemory.budgetMb)
    return Model.placeholderForDownload(
      modelId: resolved.modelId,
      mainUrl: resolved.mainUrl,
      additionalParts: resolved.additionalParts,
      mmprojUrl: resolved.mmprojUrl,
      draftUrl: resolved.draftUrl,
      fileSize: resolved.approximateBytes)
  }

  /// Whether an installed model came with an image projector. `Model.hasVisionSupport`
  /// only knows about a projector still to download, not one the cache scan found.
  func readsImages(_ model: Model) -> Bool {
    paths[model.id]?.mmprojFile != nil
  }

  func isInstalled(_ model: Model) -> Bool {
    installed.contains { $0.id == model.id }
  }

  /// Why the model may not run here, or nil when the estimate says it fits.
  func warning(for model: Model) -> String? {
    switch model.incompatibility(budgetMb: DeviceMemory.budgetMb) {
    case nil:
      return nil
    case .contextBelowMinimum:
      return "This model supports less than 4K of context."
    case .exceedsNativeContext(let nativeMaxLabel):
      return "This model is limited to \(nativeMaxLabel)."
    case .needsMemory(let mb):
      let needed = ByteCountFormatter.string(fromByteCount: Int64(mb) << 20, countStyle: .memory)
      let budget = ByteCountFormatter.string(
        fromByteCount: Int64(DeviceMemory.budgetMb) << 20, countStyle: .memory)
      return "Needs about \(needed) of memory; this device offers about \(budget). It may not load."
    }
  }

  func isDownloading(_ model: Model) -> Bool {
    downloads.contains { $0.model.id == model.id }
  }

  func install(_ model: Model) {
    if let startupTask {
      Task {
        await startupTask.value
        install(model)
      }
      return
    }
    guard !isDownloading(model) else { return }
    error = nil
    let files = model.missingFiles(cacheDir: cacheDir)
    guard !files.isEmpty else { return refresh() }
    let finished = model.cachedBytes(cacheDir: cacheDir)
    let available = DiskSpace.availableBytes(at: cacheDir)
    let remaining = model.fileSize - finished
    if available > 0, remaining > available {
      error = "Not enough storage: \(model.displayName) needs \(Self.size(remaining)), "
        + "\(Self.size(available)) is free."
      return
    }
    do {
      // Brings the download back as interrupted if it stops before the end.
      try model.writePlaceholder(cacheDir: cacheDir)
    } catch {
      self.error = error.localizedDescription
      return
    }
    interrupted.removeAll { $0.id == model.id }
    downloads.append(Download(model: model, finishedBytes: finished))
    DownloadSession.requestNotifications()
    let allowCellular = allowCellular
    Task {
      guard let plan = await HFDownloadPlan.fetch(for: model, token: token) else {
        return endDownload(
          of: model.id,
          failure: "Couldn't reach Hugging Face to start the download. Try again in a few minutes.")
      }
      // Stopped while the plan was loading.
      guard isDownloading(model) else { return }
      do {
        try session.savePlan(plan, for: model.id)
      } catch {
        return endDownload(of: model.id, failure: error.localizedDescription)
      }
      for url in files {
        updateDownload(model.id) { $0.inFlight[url] = 0 }
        session.start(url, of: model.id, allowCellular: allowCellular, token: token)
      }
    }
  }

  /// Stops a download and keeps it as interrupted, to continue later from
  /// where each file stopped.
  func stopDownload(_ model: Model) {
    guard let download = downloads.first(where: { $0.model.id == model.id }) else { return }
    if download.inFlight.isEmpty {
      // Still loading its plan: nothing is transferring yet.
      endDownload(of: model.id, failure: nil)
    } else {
      Task { await session.stop(model.id, keepingResumeData: true) }
    }
  }

  /// Forgets an interrupted download and the files it left behind.
  func discard(_ model: Model) {
    interrupted.removeAll { $0.id == model.id }
    session.discardResumeData(of: model)
    HFCache.removePartials(cacheDir: cacheDir, modelId: model.id)
    // Files it finished sit in the repo's cache dir, which nothing else may be using.
    let others = installed.compactMap { paths[$0.id]?.hfRepoDirName } + interrupted.compactMap(\.hfRepoDir)
    if let repoDir = model.hfRepoDir, !others.contains(repoDir) {
      try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent(repoDir))
    }
  }

  func remove(_ model: Model) {
    guard let paths = paths[model.id] else { return }
    do {
      try HFCache.deleteModelFiles(cacheDir: cacheDir, repoDir: paths.hfRepoDirName, paths: paths)
    } catch {
      self.error = error.localizedDescription
    }
    refresh()
  }

  static func size(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  // MARK: - Settings

  func saveToken(_ token: String) throws {
    try Keychain.setHuggingFaceToken(token)
    hasToken = true
  }

  func removeToken() {
    Keychain.removeHuggingFaceToken()
    hasToken = false
  }

  /// Space the installed models take, projectors and draft heads included.
  var installedBytes: Int64 {
    installed.reduce(0) { $0 + $1.fileSize }
  }

  var availableBytes: Int64 {
    DiskSpace.availableBytes(at: cacheDir)
  }

  // MARK: - Context and memory

  /// Whether the model's memory is still being measured. Until then only 4K is offered.
  func isEstimating(_ model: Model) -> Bool {
    model.ctxBytesPer1kTokens == 0
  }

  /// Context sizes to choose from: those the model supports that fit this device.
  func contextTiers(for model: Model) -> [ContextTier] {
    model.supportedContextTiers(budgetMb: DeviceMemory.budgetMb)
  }

  /// The context the model runs with: the one chosen while it still fits, otherwise
  /// 4K. A model estimated not to fit still gets 4K, to let it be tried; one that
  /// can't hold 4K at all gets none and can't load.
  func contextTier(for model: Model) -> ContextTier? {
    let saved = chosenContexts[model.id].flatMap(ContextTier.init(rawValue:))
    return model.effectiveCtxTier(selected: saved, budgetMb: DeviceMemory.budgetMb)
      ?? (Double(model.ctxWindow) >= Model.compatibilityCtxWindowTokens ? .k4 : nil)
  }

  func setContextTier(_ tier: ContextTier, for model: Model) {
    chosenContexts[model.id] = tier.rawValue
    writePresets()
  }

  private func writePresets() {
    let sections = ModelPreset.sections(
      for: installed, paths: paths, contextTier: contextTier(for:), largeBatch: false)
    let header = "; Generated by Llama from the installed models; rewritten on every change.\n\n"
    do {
      try (header + sections.map { $0.serialized() }.joined())
        .write(to: presetsURL, atomically: true, encoding: .utf8)
      loadableModels = sections.map(\.name)
      presetRevision += 1
    } catch {
      self.error = error.localizedDescription
    }
  }

  /// Measures the models without a cached profile, one at a time.
  private func probe(_ models: [(id: String, path: String)]) {
    let pending = models.filter { !probing.contains($0.id) }
    guard !pending.isEmpty else { return }
    probing.formUnion(pending.map(\.id))
    Task {
      for (id, path) in pending {
        let profile = await EngineController.probeMemory(modelPath: path)
        // Failures aren't cached, so the next launch measures again; -1 ends
        // "estimating" for this session.
        if let profile { MemProfileCache.set(profile, for: id) }
        probing.remove(id)
        guard let index = installed.firstIndex(where: { $0.id == id }) else { continue }
        installed[index].ctxBytesPer1kTokens = profile?.ctxBytesPer1kTokens ?? -1
        installed[index].residentBytes = profile?.residentBytes ?? 0
        writePresets()
      }
    }
  }

  // MARK: - Following the session

  private func receive(_ event: DownloadSession.Event) {
    guard !isLoading else {
      // Progress is recovered from the session snapshot; retain terminal events
      // until their model's placeholder and active transfers have been restored.
      if case .progress = event { return }
      startupEvents.append(event)
      return
    }
    handle(event)
  }

  private func handle(_ event: DownloadSession.Event) {
    switch event {
    case .progress(let modelId, let url, let bytes):
      updateDownload(modelId) { $0.inFlight[url] = bytes }
    case .finished(let modelId, let url, let bytes):
      updateDownload(modelId) {
        $0.inFlight[url] = nil
        $0.finishedBytes += bytes
      }
      endDownloadIfIdle(modelId)
    case .stopped(let modelId, let url, let message):
      updateDownload(modelId) {
        $0.inFlight[url] = nil
        if let message, $0.failure == nil { $0.failure = message }
      }
      // One file failing stops the model, keeping what the others received.
      if message != nil {
        Task { await session.stop(modelId, keepingResumeData: true) }
      }
      endDownloadIfIdle(modelId)
    }
  }

  /// Picks up transfers that outlived the app, using the placeholders the scan
  /// found for them.
  private func restoreDownloads() async {
    let transfers = await session.transfers()
    for (modelId, files) in Dictionary(grouping: transfers, by: \.modelId) {
      guard !downloads.contains(where: { $0.model.id == modelId }),
        let model = interrupted.first(where: { $0.id == modelId })
      else { continue }
      interrupted.removeAll { $0.id == modelId }
      var download = Download(model: model, finishedBytes: model.cachedBytes(cacheDir: cacheDir))
      for file in files { download.inFlight[file.url] = file.bytes }
      downloads.append(download)
    }
  }

  private func updateDownload(_ modelId: String, _ change: (inout Download) -> Void) {
    guard let index = downloads.firstIndex(where: { $0.model.id == modelId }) else { return }
    change(&downloads[index])
  }

  private func endDownloadIfIdle(_ modelId: String) {
    guard let download = downloads.first(where: { $0.model.id == modelId }),
      download.inFlight.isEmpty
    else { return }
    endDownload(of: modelId, failure: download.failure)
  }

  /// Retires a download whose files have all stopped: installed when every file
  /// landed, interrupted otherwise.
  private func endDownload(of modelId: String, failure: String?) {
    guard let index = downloads.firstIndex(where: { $0.model.id == modelId }) else { return }
    let model = downloads.remove(at: index).model
    if model.missingFiles(cacheDir: cacheDir).isEmpty {
      HFCache.removePartials(cacheDir: cacheDir, modelId: modelId)
    } else {
      // Interrupted now, not when the scan below lands: the row would vanish
      // in between.
      if !interrupted.contains(where: { $0.id == modelId }) { interrupted.append(model) }
      if let failure { error = failure }
    }
    refresh()
  }

  private func apply(_ scan: CacheScan) {
    installed = scan.models.sorted(by: Model.displayOrder)
    paths = scan.resolvedPaths
    let busy = Set(installed.map(\.id)).union(downloads.map(\.model.id))
    interrupted = scan.paused.map(\.model).filter { !busy.contains($0.id) }
    writePresets()
    probe(scan.needsProfile)
  }
}
