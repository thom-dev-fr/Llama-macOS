import Foundation
import Testing

@testable import LlamaCore

@Suite struct CompatibilityTests {
  /// 1 GiB of weights plus 8 MiB per 1k tokens of context, native window 32k:
  /// 1057 MB at 4k, 1090 at 8k, 1156 at 16k, 1287 at 32k.
  let model = Model(
    id: "org/repo:Q4_K_M", ctxWindow: 32_768, fileSize: 1 << 30,
    ctxBytesPer1kTokens: 8 << 20, residentBytes: 1 << 30,
    downloadUrl: URL(fileURLWithPath: "/"))

  @Test func tiersFollowTheBudget() {
    #expect(model.supportedContextTiers(budgetMb: 1200) == [.k4, .k8, .k16])
    #expect(model.displayContextTiers == [.k4, .k8, .k16, .k32])
    #expect(model.nativeMaxTier == .k32)
  }

  @Test func selectedTierFallsBackTo4kWhenItNoLongerFits() {
    #expect(model.effectiveCtxTier(selected: .k16, budgetMb: 1200) == .k16)
    #expect(model.effectiveCtxTier(selected: .k32, budgetMb: 1200) == .k4)
    #expect(model.effectiveCtxTier(selected: nil, budgetMb: 1000) == nil)
  }

  @Test func reportsWhyAModelDoesNotFit() {
    #expect(model.incompatibility(budgetMb: 1200) == nil)
    #expect(model.incompatibility(budgetMb: 0) == .needsMemory(mb: 1057))
    #expect(
      model.incompatibility(ctxWindowTokens: 65_536, budgetMb: 10_000)
        == .exceedsNativeContext(nativeMaxLabel: "32k ctx"))
    let tiny = Model(id: "a/b:Q8_0", ctxWindow: 2048, fileSize: 1, downloadUrl: model.downloadUrl)
    #expect(tiny.incompatibility(budgetMb: 10_000) == .contextBelowMinimum)
  }

  @Test func unprofiledModelsOnlyOffer4k() {
    let unprofiled = Model(id: "a/b:Q8_0", fileSize: 1, downloadUrl: model.downloadUrl)
    #expect(unprofiled.supportedContextTiers(budgetMb: 100_000) == [.k4])
  }
}

@Suite struct CacheTests {
  let main = URL(string: "https://huggingface.co/org/Repo-GGUF/resolve/main/Repo-Q4_K_M.gguf")!
  let mmproj = URL(string: "https://huggingface.co/org/Repo-GGUF/resolve/main/mmproj-Repo-f16.gguf")!

  @Test func interruptedDownloadComesBackAsPaused() throws {
    let cacheDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheDir) }
    let model = Model(
      id: "org/Repo-GGUF:Q4_K_M", fileSize: 2_000_000, downloadUrl: main, mmprojUrl: mmproj)

    #expect(model.missingFiles(cacheDir: cacheDir) == [main, mmproj])

    try model.writePlaceholder(cacheDir: cacheDir)
    let scan = CacheScan(cacheDir: cacheDir)
    #expect(scan.models.isEmpty)
    #expect(scan.paused.map(\.model.id) == [model.id])
    #expect(scan.paused.first?.model.mmprojUrl == mmproj)
  }

  @Test func modelMissingItsProjectorIsNotInstalledYet() throws {
    let cacheDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheDir) }
    let model = Model(
      id: "org/Repo-GGUF:Q4_K_M", fileSize: 2_000_000, downloadUrl: main, mmprojUrl: mmproj)
    try model.writePlaceholder(cacheDir: cacheDir)
    let snapshot = cacheDir.appendingPathComponent("models--org--Repo-GGUF/snapshots/abc")
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    try Data(count: 1024).write(to: snapshot.appendingPathComponent("Repo-Q4_K_M.gguf"))

    let partial = CacheScan(cacheDir: cacheDir)
    #expect(!partial.models.contains { $0.id == model.id })
    #expect(partial.paused.map(\.model.id) == [model.id])
    #expect(FileManager.default.fileExists(
      atPath: HFCache.placeholderURL(cacheDir: cacheDir, modelId: model.id).path))

    try Data(count: 1024).write(to: snapshot.appendingPathComponent("mmproj-Repo-f16.gguf"))
    #expect(CacheScan(cacheDir: cacheDir).paused.isEmpty)
  }
}
