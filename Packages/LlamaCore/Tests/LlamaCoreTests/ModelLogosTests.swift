import AppKit
import Testing

@testable import LlamaCore

@Suite struct ModelLogosTests {
  /// Every brand the table names resolves to an image in the package's catalog,
  /// so neither app falls back to the generic symbol over a missing asset.
  @Test(arguments: [
    "Qwen3.5", "gemma-3", "gpt-oss", "Ministral", "GLM-4.7", "Nemotron", "Laguna",
    "DeepSeek-R1", "clef", "LFM2.5",
  ])
  func brandResolvesToBundledImage(_ name: String) throws {
    let asset = try #require(ModelLogos.asset(matching: name))
    #expect(ModelLogos.bundle.image(forResource: asset) != nil)
  }

  @Test func unknownBrandHasNoLogo() {
    #expect(ModelLogos.asset(matching: "Llama-3.2") == nil)
  }
}
