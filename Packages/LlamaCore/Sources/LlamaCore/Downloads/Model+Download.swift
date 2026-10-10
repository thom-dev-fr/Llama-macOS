import Foundation

/// What a download of this model needs from the HF cache, independent of how
/// the bytes are transferred.
extension Model {
  /// The remote files (main, shards, mmproj, draft head) not yet in the cache's
  /// snapshots. A model already found installed by a scan needs no check.
  public func missingFiles(cacheDir: URL) -> [URL] {
    allDownloadUrls.filter { !isInCache($0, cacheDir: cacheDir) }
  }

  /// Bytes of this model's files already in the cache's snapshots -- what a
  /// download resumed after a relaunch has already done.
  public func cachedBytes(cacheDir: URL) -> Int64 {
    guard let repoDir = hfRepoDir else { return 0 }
    let snapshots = cacheDir.appendingPathComponent(repoDir).appendingPathComponent("snapshots")
    let commits = (try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? []
    return allDownloadUrls.reduce(0) { total, url in
      let filename = HFCache.repoRelativePath(from: url) ?? url.lastPathComponent
      let size = commits.lazy.map {
        let link = snapshots.appendingPathComponent($0).appendingPathComponent(filename)
        // Snapshot entries are symlinks into blobs/; the size is the blob's.
        return FileManager.default.fileSize(atPath: link.resolvingSymlinksInPath().path)
      }.first { $0 > 0 }
      return total + (size ?? 0)
    }
  }

  /// Writes this model's placeholder JSON into its partial dir so the paused
  /// row can be rebuilt at launch (see `CacheScan.paused`). The placeholder
  /// dies with the partial dir on completion/cancel.
  public func writePlaceholder(cacheDir: URL) throws {
    let url = HFCache.placeholderURL(cacheDir: cacheDir, modelId: id)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(self).write(to: url, options: .atomic)
  }

  /// Checks if a file exists in the HF cache for this model and remote URL.
  private func isInCache(_ url: URL, cacheDir: URL) -> Bool {
    guard let repoDir = hfRepoDir else { return false }
    let filename = HFCache.repoRelativePath(from: url) ?? url.lastPathComponent
    return HFCache.snapshotFileExists(cacheDir: cacheDir, repoDir: repoDir, filename: filename)
  }
}
