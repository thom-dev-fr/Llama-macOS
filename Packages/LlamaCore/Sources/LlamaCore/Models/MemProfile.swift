import CryptoKit
import Foundation
import os.log

/// Per-model memory profile: parameters of an affine estimator that predicts
/// total memory at any context size. Currently produced by probing with
/// `llama fit-params`, but the data is independent of how it's measured.
/// Cached to disk so we don't re-run on every launch.
///
/// All fields are non-optional on purpose: when we add a new field, synthesized
/// Codable fails to decode old cache entries (keyNotFound), `MemProfileCache.get`
/// returns nil, and we re-probe to produce a fresh entry. Don't switch to
/// `decodeIfPresent` or a custom `init(from:)` with defaults — that would
/// silently keep stale entries across upgrades.
public struct MemProfile: Codable, Sendable {
  /// Slope of the affine memory model, in bytes per 1k tokens.
  ///   mem(ctx) = residentBytes + ctxBytesPer1kTokens · ctx / 1000
  /// Maps directly to Model.ctxBytesPer1kTokens.
  public let ctxBytesPer1kTokens: Int
  /// Intercept of the affine memory model, in bytes. Total footprint at ctx=0 —
  /// includes model weights, compute buffers, and any ctx-independent KV state
  /// (e.g. the per-layer local cache that SWA models like Gemma keep regardless
  /// of ctx). Maps to Model.residentBytes.
  /// 0 if unknown (e.g. probe failed).
  public let residentBytes: Int
  /// Schema version. Bumping invalidates on-disk caches via the Codable
  /// keyNotFound mechanism documented at the top of this file.
  /// v2: switched from single-probe debug-table parse to two-probe -fitp affine
  ///     fit. Semantics of both above fields changed — v1 caches are discarded.
  public let schemaVersion: Int

  public init(ctxBytesPer1kTokens: Int, residentBytes: Int = 0) {
    self.ctxBytesPer1kTokens = ctxBytesPer1kTokens
    self.residentBytes = residentBytes
    self.schemaVersion = 2
  }
}

extension MemProfile {
  /// The two context sizes a model's total memory is measured at, in tokens.
  public static let probeContexts: (low: UInt32, high: UInt32) = (4096, 131072)

  private static let logger = Logger(subsystem: Logging.subsystem, category: "MemProfile")

  /// Fits an affine memory model through two measurements of a model's total
  /// footprint (weights, context and compute buffers on every device), taken
  /// at `probeContexts`:
  ///   mem(ctx) = a + b·ctx
  /// where `a` becomes residentBytes and `b·1000` becomes ctxBytesPer1kTokens.
  ///
  /// Why two probes, not one: memory is not purely linear in ctx. SWA models
  /// (Gemma family) keep a fixed-size per-layer local KV cache regardless of
  /// ctx, which shows up as a non-zero intercept (~174 MiB on Gemma 3 4B).
  /// Dividing a single 128k probe by 128 folds that intercept into the slope
  /// and mis-predicts small-ctx usage by multiple hundreds of MiB. A two-point
  /// affine fit recovers both terms correctly and degenerates cleanly to
  /// near-linear for dense models (where a ≈ 0).
  ///
  /// Returns nil when the measurements can't be right.
  public static func fit(totalMibAtLow loMib: Int, totalMibAtHigh hiMib: Int) -> MemProfile? {
    let (ctxLo, ctxHi) = probeContexts

    // Affine fit: solve a + b·ctx_lo = lo, a + b·ctx_hi = hi.
    let dc = Double(ctxHi - ctxLo)
    let bPerToken = Double(hiMib - loMib) / dc  // MiB per token
    let aMib = Double(loMib) - bPerToken * Double(ctxLo)  // MiB at ctx=0

    // A negative slope means total memory went down as ctx grew — that's not
    // a real outcome, it signals a broken probe. Failing here routes the
    // caller to the file-size fallback, instead of silently producing a
    // "memory is ctx-independent" estimate that would accept any ctx and
    // risk OOM at runtime.
    guard bPerToken >= 0 else {
      logger.error(
        "Fit params: non-monotonic total (\(loMib) MiB at \(ctxLo) vs \(hiMib) MiB at \(ctxHi))"
      )
      return nil
    }

    // Clamp the intercept only — small negatives can appear from MiB rounding
    // at the probe points, or from a compute-buffer step that only shows up
    // at the high ctx. Overestimating the intercept is the safe direction.
    let aBytes = Int(max(aMib, 0) * 1_048_576.0)
    // Floor the slope at 1 byte/1k: `Model.ctxBytesPer1kTokens == 0` is the
    // "probe pending" sentinel, so a measured zero would leave the row on
    // "estimating..." forever. Real zeros happen -- decision models like Laya
    // keep no KV cache that grows with ctx (482 MiB at both 4k and 128k).
    let bBytesPer1k = max(Int(bPerToken * 1000.0 * 1_048_576.0), 1)

    logger.info(
      "Mem profile (affine): total(\(ctxLo))=\(loMib) MiB, total(\(ctxHi))=\(hiMib) MiB → a=\(aBytes) bytes, b=\(bBytesPer1k) bytes/1k"
    )

    return MemProfile(ctxBytesPer1kTokens: bBytesPer1k, residentBytes: aBytes)
  }
}

/// Disk cache for `MemProfile` results.
/// Stored in the app's Caches directory under {bundleId}/MemProfile/ — the standard
/// location for derived, recreatable data. If the system purges the cache, we
/// re-probe.
public enum MemProfileCache {

  private static let logger = Logger(subsystem: Logging.subsystem, category: "MemProfileCache")

  /// Returns the cached MemProfile for a model ID, or nil if not cached.
  public static func get(modelId: String) -> MemProfile? {
    let path = cachePath(for: modelId)
    guard let data = try? Data(contentsOf: path) else { return nil }
    return try? JSONDecoder().decode(MemProfile.self, from: data)
  }

  /// Stores a MemProfile for a model ID.
  public static func set(_ profile: MemProfile, for modelId: String) {
    let path = cachePath(for: modelId)
    do {
      try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      let data = try JSONEncoder().encode(profile)
      try data.write(to: path, options: .atomic)
    } catch {
      logger.error("Failed to cache mem profile for \(modelId): \(error.localizedDescription)")
    }
  }

  // MARK: - Private

  /// Returns the cache file path for a model ID.
  /// Uses SHA256 of the model ID to avoid filesystem-unfriendly characters.
  private static func cachePath(for modelId: String) -> URL {
    let hash = sha256(modelId)
    return cacheDir.appendingPathComponent("\(hash).json")
  }

  private static var cacheDir: URL {
    let bundleId = Bundle.main.bundleIdentifier ?? "app.llama.Llama"
    return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
      .appendingPathComponent(bundleId)
      .appendingPathComponent("MemProfile")
  }

  /// First 16 bytes of the SHA256, hex-encoded. Truncated to keep file names
  /// short; changing the length would orphan every existing cache entry.
  private static func sha256(_ string: String) -> String {
    SHA256.hash(data: Data(string.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
  }
}
