import Foundation

/// Metadata gathered from the HF API before starting a download.
/// Provides the information needed to write files into the HF cache layout.
public struct HFDownloadPlan: Codable, Sendable {
  /// HF cache repo directory name (e.g. "models--unsloth--Qwen3.5-2B-GGUF")
  public let repoDir: String
  /// Git commit hash for the snapshot directory
  public let commit: String
  /// Maps each remote download URL to its content SHA256 hash (blob name).
  /// URLs whose hash couldn't be obtained from the API are absent —
  /// their hash must be computed after download.
  public var blobHashes: [URL: String]

  public init(repoDir: String, commit: String, blobHashes: [URL: String]) {
    self.repoDir = repoDir
    self.commit = commit
    self.blobHashes = blobHashes
  }

  /// Fetches HF file metadata (commit hash, blob hashes) for a model via HEAD requests.
  /// Each HEAD request returns both X-Repo-Commit and X-Linked-Etag, so one request
  /// per file gives us everything we need. Returns nil on failure (caller aborts download).
  public static func fetch(for model: Model, token: String?) async -> HFDownloadPlan? {
    guard let repoDir = HFCache.repoDirName(from: model.downloadUrl) else { return nil }

    let allMetadata = await HFCache.fetchFileMetadata(
      for: model.allDownloadUrls, token: token)
    guard !allMetadata.isEmpty else { return nil }

    // All files in a repo share the same commit hash — take the first one we get
    let commit = allMetadata.values.compactMap(\.commitHash).first
    guard let commit else { return nil }

    // Collect blob hashes (some may be nil if header was missing)
    let blobHashes = allMetadata.compactMapValues(\.blobHash)

    return HFDownloadPlan(repoDir: repoDir, commit: commit, blobHashes: blobHashes)
  }
}
