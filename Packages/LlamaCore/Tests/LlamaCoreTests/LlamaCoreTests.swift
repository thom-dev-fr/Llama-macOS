import Foundation
import Testing

@testable import LlamaCore

@Suite struct ModelIdTests {
  @Test func idRoundTripsThroughBase() {
    let id = Model.makeId(orgSlashRepo: "unsloth/Qwen3.5-2B-GGUF", tag: "Q4_K_M")
    #expect(id == "unsloth/Qwen3.5-2B-GGUF:Q4_K_M")
    let model = Model(id: id, fileSize: 1, downloadUrl: URL(fileURLWithPath: "/"))
    #expect(model.idBase == "unsloth/Qwen3.5-2B-GGUF")
  }

  @Test func parsesDisplayParts() {
    let parsed = ModelIdParser.parse("ggml-org/gemma-3-4b-it-GGUF:Q4_K_M")
    #expect(parsed.displayOrg == nil)
    #expect(parsed.name == "gemma-3")
    #expect(parsed.params == "4B")
    #expect(parsed.quant == "Q4_K_M")
    #expect(parsed.tags == ["it"])
  }

  @Test func weightEstimateLetsUnknownSizesThrough() {
    #expect(Model.estimatedWeightFits(bytes: nil, budgetMb: 0))
    #expect(Model.estimatedWeightFits(bytes: 1 << 30, budgetMb: 2000))
    // 1 GiB plus 5% overhead is 1075 MB.
    #expect(!Model.estimatedWeightFits(bytes: 1 << 30, budgetMb: 1000))
  }
}

@Suite struct HFParsingTests {
  @Test func splitsRepoDirectory() {
    let parsed = HFRepoParser.parse(repoDir: "models--bartowski--Llama-3.2-1B-Instruct-GGUF")
    #expect(parsed?.org == "bartowski")
    #expect(parsed?.repo == "Llama-3.2-1B-Instruct-GGUF")
    #expect(HFRepoParser.parse(repoDir: "datasets--a--b") == nil)
  }

  @Test func readsQuantFromFilenames() {
    #expect(HFRepoParser.parseQuant(filename: "Llama-3.2-1B-Instruct-Q4_K_M.gguf") == "Q4_K_M")
    let shard = "Qwen3.5-122B-A10B-Q4_K_M-00001-of-00003.gguf"
    #expect(HFRepoParser.parseQuant(filename: shard) == "Q4_K_M")
    #expect(HFRepoParser.isFirstShard(shard))
    #expect(HFRepoParser.shardTotal(shard) == 3)
    #expect(!HFRepoParser.isFirstShard("Qwen3.5-122B-A10B-Q4_K_M-00002-of-00003.gguf"))
  }

  @Test func recognizesProjector() {
    #expect(SidecarPicker.isMmproj("mmproj-model-f16.gguf"))
    #expect(!SidecarPicker.isMmproj("gemma-3-4b-it-Q4_K_M.gguf"))
  }
}

@Suite struct LlamaURLTests {
  @Test func parsesInstallLinks() {
    #expect(
      LlamaURL.parse(URL(string: "llama://install?repo=ggml-org/gemma-3-4b-it-GGUF&quant=Q8_0")!)
        == .install(repo: "ggml-org/gemma-3-4b-it-GGUF", quant: "Q8_0"))
    #expect(
      LlamaURL.parse(URL(string: "llama://install?repo=org/name&quant=")!)
        == .install(repo: "org/name", quant: nil))
  }

  @Test func rejectsInvalidLinks() {
    #expect(LlamaURL.parse(URL(string: "llama://install?repo=no-slash")!) == nil)
    #expect(LlamaURL.parse(URL(string: "llama://open?repo=org/name")!) == nil)
    #expect(LlamaURL.parse(URL(string: "https://install?repo=org/name")!) == nil)
  }
}
