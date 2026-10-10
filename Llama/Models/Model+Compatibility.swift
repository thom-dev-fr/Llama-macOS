import Foundation
import LlamaCore

/// The Mac's side of compatibility: its memory budget and how an
/// incompatibility reads in the menu. The arithmetic lives in LlamaCore.
extension Model {
  // MARK: - Memory Budget

  /// Slack (in MB) left inside the GPU working set for what the memory
  /// estimate can't see: allocation rounding, a model still resident while the
  /// next one loads. llama.cpp's own default for `--fit-target`, and their
  /// number for the error in the fit we rely on.
  static let fitSlackMb: Double = 1024

  /// Physical RAM (in MB) kept out of a model's reach for macOS and other
  /// apps. Absolute rather than proportional, because the desktop's needs
  /// don't shrink on a small Mac -- which is the whole reason this exists.
  /// On roomy machines the working set already leaves far more than this
  /// unused, so the term does nothing; on an 8 GB Mac the working set leaves
  /// only ~2 GB outside itself and this is what pulls the budget down.
  static let osFloorMb: Double = 4096

  /// The memory a model may use on this device -- whichever of the two limits
  /// binds first:
  ///
  /// - `workingSet - fitSlack`: what the GPU will hold, less llama.cpp's
  ///   margin. We read Metal's working set rather than taking a fraction of
  ///   `hw.memsize` because Apple's ratio varies by machine (~75% on common
  ///   configurations, 84% measured on a 128 GB Mac) -- assuming 75%
  ///   understated large Macs and blocked sizes that run fine. llama.cpp
  ///   treats the same figure as the device's total and fits against it, so
  ///   this side matches `serve`'s own limit.
  /// - `physicalRam - osFloor`: leaves the desktop enough to work with. Only
  ///   binds on small Macs, where the memory outside the working set isn't
  ///   enough to host macOS on its own.
  ///
  /// With `useFullWorkingSet` set, the GPU limb is the working set itself --
  /// llama.cpp's fit slack is spent rather than held back. That's the whole
  /// override: it never exceeds what Metal recommends, so the machine is never
  /// pushed into swap by our arithmetic. Worth a gigabyte on every Mac, and a
  /// gigabyte is the difference for a model that lands just over the line.
  ///
  /// The floor stays at `osFloorMb` in both modes, which makes the flag inert
  /// on an 8 GB Mac (the floor is already what governs there). That's
  /// deliberate: taking a model past ~4 GB on an 8 GB machine doesn't just
  /// slow it down, it wedges it hard enough that the process can't be quit.
  static var deviceMemoryBudgetMb: Double {
    let workingSetMb = Double(SystemMemory.gpuWorkingSetMb)
    let physicalMb = Double(SystemMemory.memoryMb)
    let ramLimbMb = physicalMb - osFloorMb
    let gpuLimbMb =
      UserSettings.useFullWorkingSet ? workingSetMb : workingSetMb - fitSlackMb
    return max(min(gpuLimbMb, ramLimbMb), 0)
  }

  /// The margin to hand `serve` as `--fit-target`: everything between the
  /// working set and our budget, so its runtime fit lands on the same number
  /// our predictions do. Larger than `fitSlackMb` exactly when the OS floor is
  /// the binding limit.
  static var fitTargetMb: Double {
    max(Double(SystemMemory.gpuWorkingSetMb) - deviceMemoryBudgetMb, 0)
  }

  // MARK: - Compatibility on this Mac

  func isCompatible(
    ctxWindowTokens: Double = compatibilityCtxWindowTokens
  ) -> Bool {
    incompatibility(ctxWindowTokens: ctxWindowTokens, budgetMb: Self.deviceMemoryBudgetMb) == nil
  }

  func incompatibilitySummary(
    ctxWindowTokens: Double = compatibilityCtxWindowTokens
  ) -> String? {
    switch incompatibility(ctxWindowTokens: ctxWindowTokens, budgetMb: Self.deviceMemoryBudgetMb) {
    case nil:
      return nil
    case .contextBelowMinimum:
      return "requires models with ≥4k context"
    case .exceedsNativeContext(let nativeMaxLabel):
      return "model max is \(nativeMaxLabel)"
    case .needsMemory(let mb):
      return Self.memoryRequirementSummary(neededMb: Double(mb))
    }
  }

  /// Context tiers this Mac can run -- the ones the picker leaves selectable.
  var supportedContextTiers: [ContextTier] {
    supportedContextTiers(budgetMb: Self.deviceMemoryBudgetMb)
  }

  /// The effective context tier for this model.
  /// Returns user's selection if set and still compatible, otherwise 4K.
  /// Models that don't chat always get 4K (see the LlamaCore overload).
  var effectiveCtxTier: ContextTier? {
    effectiveCtxTier(
      selected: UserSettings.selectedCtxTier(for: id), budgetMb: Self.deviceMemoryBudgetMb)
  }

  /// Works back from a requirement to a Mac that could meet it, inverting
  /// both limbs of the budget and taking whichever demands more RAM. The
  /// working-set limb needs Apple's ratio, which we can only measure on
  /// *this* machine, so sizing another one assumes the usual ~75% -- fine
  /// for naming a memory tier, too rough to gate anything on.
  private static func memoryRequirementSummary(neededMb: Double) -> String {
    let fromWorkingSet = (neededMb + fitSlackMb) / 0.75
    let fromOsFloor = neededMb + osFloorMb
    let requiredTotalMb = max(fromWorkingSet, fromOsFloor)
    let gb = ceil(requiredTotalMb / 1024.0)

    let commonSizes: [Double] = [8, 16, 18, 24, 32, 36, 48, 64, 96, 128, 192]
    let displayGb = commonSizes.first(where: { $0 >= gb }) ?? gb

    return String(format: "Requires a Mac with %.0f GB+ of memory", displayGb)
  }
}
