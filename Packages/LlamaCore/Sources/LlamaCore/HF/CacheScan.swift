import Foundation

/// Everything one pass over the HF cache finds: installed models, with any
/// cached memory profile applied, where their files are, which ones still need
/// profiling, and downloads an earlier session left unfinished.
///
/// A model whose download placeholder is still on disk counts as installed only
/// once every file it lists is in the cache. Until then it is paused, even if
/// its main file already landed and the scan can see it -- otherwise a scan
/// during a download would report the model installed without its projector or
/// remaining shards, and delete the staging dir those files are being written to.
///
/// The scan is pure disk work with no app state involved, so it can run on any
/// thread. It does have one side effect: partial dirs whose model is now
/// installed are garbage-collected.
public struct CacheScan: Sendable {
  public var models: [Model]
  public var resolvedPaths: [String: ResolvedPaths]
  /// Installed models without a cached `MemProfile`: id and main file path,
  /// for the caller to probe.
  public var needsProfile: [(id: String, path: String)]
  /// Downloads interrupted in a previous session, rebuilt from the placeholder
  /// each download writes (`Model.writePlaceholder`), with their bytes on disk.
  public var paused: [(model: Model, bytesOnDisk: Int64)]

  public init(cacheDir hfCacheDir: URL) {
    // Rehydrate paused rows for downloads interrupted in a previous session:
    // decode each on-disk placeholder back into a `Model` and pair it with its
    // current bytes-on-disk. No network resolve needed — the placeholder
    // carries the full `Model`. Placeholders whose files have all landed belong
    // to finished downloads, so they count as installed.
    let pausedEntries = HFCache.scanPlaceholders(cacheDir: hfCacheDir).compactMap {
      url -> (model: Model, bytesOnDisk: Int64)? in
      guard let data = try? Data(contentsOf: url),
        let model = try? JSONDecoder().decode(Model.self, from: data),
        !model.missingFiles(cacheDir: hfCacheDir).isEmpty
      else { return nil }
      return (model, HFCache.partialBytes(cacheDir: hfCacheDir, modelId: model.id))
    }
    let unfinished = Set(pausedEntries.map(\.model.id))

    let discovered = HFCache.scanForSideloaded(cacheDir: hfCacheDir)
      .filter { !unfinished.contains($0.entry.id) }

    // Apply cached mem-profile when available; queue the rest for async probing.
    var resolvedPaths: [String: ResolvedPaths] = [:]
    var models: [Model] = []
    var needsProfile: [(id: String, path: String)] = []
    for (entry, paths) in discovered {
      var entry = entry
      if let cached = MemProfileCache.get(modelId: entry.id) {
        entry.ctxBytesPer1kTokens = cached.ctxBytesPer1kTokens
        entry.residentBytes = cached.residentBytes
      } else {
        needsProfile.append((id: entry.id, path: paths.modelFile))
      }
      resolvedPaths[entry.id] = paths
      models.append(entry)
    }

    // Garbage-collect partial dirs whose target is now installed.
    let installedIds = Set(models.map(\.id))
    HFCache.cleanInstalledPartials(cacheDir: hfCacheDir, installedIds: installedIds)

    self.models = models
    self.resolvedPaths = resolvedPaths
    self.needsProfile = needsProfile
    self.paused = pausedEntries
  }
}
