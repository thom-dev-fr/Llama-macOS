import Foundation

/// Whether a model fits a device, as pure arithmetic over the model's measured
/// memory profile and a memory budget the caller supplies. Each app derives
/// its own budget (`Model.deviceMemoryBudgetMb` on macOS) and words the
/// `Incompatibility` for its own users; nothing here reads the device or
/// settings.
extension Model {
  // MARK: - Memory Calculations

  /// We evaluate compatibility assuming a 4k-token context, which is the
  /// default llama.cpp launches with when no explicit value is provided.
  /// Models must also support at least this context length to launch.
  public static let compatibilityCtxWindowTokens: Double = 4_096

  /// Overhead multiplier applied to the model file size when estimating weight
  /// memory without a MemProfile measurement. 1.05 = 5% overhead.
  public static let weightOverheadMultiplier = 1.05

  /// Why a model can't run at a given context within a budget.
  public enum Incompatibility: Equatable, Sendable {
    /// The model's native context is below `compatibilityCtxWindowTokens`.
    case contextBelowMinimum
    /// The requested context exceeds the model's native window, whose largest
    /// tier is labeled `nativeMaxLabel` (e.g. "32k ctx").
    case exceedsNativeContext(nativeMaxLabel: String)
    /// The estimated footprint, in MB, exceeds the budget -- or the budget is
    /// unknown (0), in which case the requirement is reported rather than
    /// guessing that it fits.
    case needsMemory(mb: UInt64)
  }

  /// Rough pre-download fit check used by the deeplink resolver and the
  /// Discover picks: model weight memory ≈ fileSize × 1.05 must be within
  /// budget. Unknown sizes pass — don't filter out. The real compatibility
  /// check runs at launch once the MemProfile probe has measured resident bytes.
  public static func estimatedWeightFits(bytes: Int64?, budgetMb: Double) -> Bool {
    guard let bytes, bytes > 0 else { return true }
    let weightMb = Double(bytes) / 1_048_576.0 * weightOverheadMultiplier
    return weightMb <= budgetMb
  }

  public func runtimeMemoryUsageMb(
    ctxWindowTokens: Double = compatibilityCtxWindowTokens
  ) -> UInt64 {
    // Memory calculations use binary units so they line up with Activity Monitor.
    let weightMb = weightMemoryMb
    let ctxMultiplier = ctxWindowTokens / 1_000.0
    let ctxBytes = Double(ctxBytesPer1kTokens) * ctxMultiplier
    let ctxMb = ctxBytes / 1_048_576.0
    let totalMb = weightMb + ctxMb
    return UInt64(ceil(totalMb))
  }

  /// Nil when the model runs at `ctxWindowTokens` within `budgetMb`.
  public func incompatibility(
    ctxWindowTokens: Double = compatibilityCtxWindowTokens, budgetMb: Double
  ) -> Incompatibility? {
    if Double(ctxWindow) < Self.compatibilityCtxWindowTokens {
      return .contextBelowMinimum
    }

    if ctxWindowTokens > 0 && ctxWindowTokens > Double(ctxWindow) {
      // Model's native context window is smaller than requested
      let maxLabel = nativeMaxTier?.label ?? "\(ctxWindow / 1024)k"
      return .exceedsNativeContext(nativeMaxLabel: maxLabel)
    }

    let estimatedMemoryUsageMb = runtimeMemoryUsageMb(ctxWindowTokens: ctxWindowTokens)

    // No budget means we couldn't read the device's memory at all; report the
    // requirement rather than guessing that it fits.
    guard budgetMb > 0, estimatedMemoryUsageMb <= UInt64(budgetMb) else {
      return .needsMemory(mb: estimatedMemoryUsageMb)
    }
    return nil
  }

  /// Context tiers the device can actually run within `budgetMb` -- the ones
  /// the picker leaves selectable.
  /// When the MemProfile probe is still pending (or failed), returns only 4K as a safe
  /// default — without `ctxBytesPer1kTokens`, memory estimates are artificially low and
  /// all tiers would falsely appear compatible.
  public func supportedContextTiers(budgetMb: Double) -> [ContextTier] {
    if ctxBytesPer1kTokens <= 0 {
      return [.k4]
    }

    func fits(_ tier: ContextTier) -> Bool {
      incompatibility(ctxWindowTokens: Double(tier.rawValue), budgetMb: budgetMb) == nil
    }

    var tiers = ContextTier.standardTiers.filter(fits)

    if fits(.k256), !tiers.contains(.k256) {
      tiers.append(.k256)
    }

    return tiers.sorted()
  }

  /// All tiers the model itself supports (within its native context window),
  /// regardless of whether this device has the memory to run them. The picker
  /// shows these, disabling the ones not in `supportedContextTiers`, so the
  /// user can see the model's full range rather than a silently truncated one.
  public var displayContextTiers: [ContextTier] {
    if ctxBytesPer1kTokens <= 0 {
      return [.k4]
    }

    var tiers = ContextTier.standardTiers.filter { $0.rawValue <= ctxWindow }
    if ContextTier.k256.rawValue <= ctxWindow {
      tiers.append(.k256)
    }
    return tiers.sorted()
  }

  /// The largest standard tier that fits within the model's native context window.
  /// Independent of device RAM -- this is the model's spec ceiling.
  public var nativeMaxTier: ContextTier? {
    ContextTier.allCases.last { $0.rawValue <= ctxWindow }
  }

  /// The context tier to run with: the user's `selected` tier while it still
  /// fits `budgetMb`, otherwise 4K. Nil when nothing fits.
  ///
  /// Models that don't chat always get 4K. For them context is the longest
  /// input they accept, and their inputs -- a ticket, a message, a chunk of a
  /// document -- are short and self-contained, unlike a conversation that keeps
  /// growing; a larger context would mostly spend memory for nothing. So
  /// their page has no picker, and a selection saved before that (decision
  /// models had one in 0.44.0) is ignored rather than left invisibly in force.
  public func effectiveCtxTier(selected: ContextTier?, budgetMb: Double) -> ContextTier? {
    let supported = supportedContextTiers(budgetMb: budgetMb)
    guard !supported.isEmpty else { return nil }

    if kind != .chat {
      return supported.contains(.k4) ? .k4 : supported.first
    }

    if let selected, supported.contains(selected) {
      return selected
    }

    return .k4
  }

  // MARK: - Weights

  /// Weight memory (MB) used by compatibility math -- the part of
  /// `runtimeMemoryUsageMb` that doesn't grow with the context.
  /// Prefers the measured `residentBytes` (correct for MoE models). Falls
  /// back to `fileSize * weightOverheadMultiplier` when the MemProfile probe
  /// hasn't landed yet (pre-download placeholders).
  public var weightMemoryMb: Double {
    if residentBytes > 0 {
      return Double(residentBytes) / 1_048_576.0
    }
    let fileSizeMb = Double(fileSize) / 1_048_576.0
    return fileSizeMb * Self.weightOverheadMultiplier
  }
}
