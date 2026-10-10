import Foundation
import Testing

@testable import LlamaCore

@Suite struct PresetTests {
  let main = URL(string: "https://huggingface.co/org/Repo-GGUF/resolve/main/Repo-Q4_K_M.gguf")!

  @Test func generatesASectionPerRunnableModel() {
    let vision = Model(id: "org/Repo-GGUF:Q4_K_M", fileSize: 1, downloadUrl: main)
    let missing = Model(id: "org/Other-GGUF:Q8_0", fileSize: 1, downloadUrl: main)
    let paths = ResolvedPaths(
      modelFile: "/m/Repo-Q4_K_M.gguf", additionalParts: [], mmprojFile: "/m/mmproj.gguf",
      usesMTP: false, draftSidecarFile: nil, hfRepoDirName: "models--org--Repo-GGUF")

    let sections = ModelPreset.sections(
      for: [vision, missing], paths: [vision.id: paths], contextTier: { _ in .k8 }, largeBatch: true)

    #expect(sections.map(\.name) == [vision.id])
    #expect(sections.first?.serialized() == """
      [org/Repo-GGUF:Q4_K_M]
      model = /m/Repo-Q4_K_M.gguf
      ctx-size = 8192
      mmproj = /m/mmproj.gguf
      ubatch-size = 2048
      tags = chat


      """)
  }

  @Test func overridesWinPerKeyAndAddUnknownSections() {
    let generated = ModelPreset.parse("[a]\nmodel = /a.gguf\nctx-size = 4096\n")
    let overrides = ModelPreset.parse("; mine\n[a]\nctx-size = 32768\ntemp = 0.7\n[b]\nmodel = /b.gguf\n")
    let merged = ModelPreset.merge(generated, overrides: overrides)
    #expect(merged.map(\.name) == ["a", "b"])
    #expect(merged[0].pairs.map(\.key) == ["model", "ctx-size", "temp"])
    #expect(merged[0].value("ctx-size") == "32768")
  }

  @Test func memoryFitSeparatesWeightsFromContext() throws {
    // 1000 MiB at 4k, 4000 MiB at 128k: 3000 MiB over 126,976 tokens.
    let profile = try #require(MemProfile.fit(totalMibAtLow: 1000, totalMibAtHigh: 4000))
    #expect(profile.ctxBytesPer1kTokens == Int(3000.0 / 126_976 * 1000 * 1_048_576))
    #expect(abs(profile.residentBytes - Int((1000 - 3000.0 / 126_976 * 4096) * 1_048_576)) <= 1)
    #expect(MemProfile.fit(totalMibAtLow: 2000, totalMibAtHigh: 1000) == nil)
  }
}
