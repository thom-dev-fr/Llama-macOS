import Foundation
import Testing

@testable import LlamaCore

@Suite struct ModelCapabilitiesTests {
  @Test func qwenTemplateThinksAndCallsTools() {
    let template = """
      {%- if tools %}<tools>{{ tool | tojson }}</tools>{%- endif %}
      {%- if enable_thinking is false %}<think>\n\n</think>{%- endif %}
      """
    #expect(
      Model.Capabilities(chatTemplate: template, hasAudioEncoder: false) == [.reasoning, .tools])
  }

  @Test func gptOssReasoningEffortCounts() {
    let template = "Reasoning: {{ reasoning_effort | default('medium') }}"
    #expect(Model.Capabilities(chatTemplate: template, hasAudioEncoder: false) == [.reasoning])
  }

  @Test func plainTemplateHasNone() {
    let template = "{% for message in messages %}<|im_start|>{{ message['content'] }}{% endfor %}"
    #expect(Model.Capabilities(chatTemplate: template, hasAudioEncoder: false).isEmpty)
    #expect(Model.Capabilities(chatTemplate: nil, hasAudioEncoder: true) == [.audio])
  }

  @Test func readsTemplateAndAudioEncoderFromHeaders() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ModelCapabilitiesTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let model = dir.appendingPathComponent("model.gguf")
    try gguf([("general.architecture", .string("qwen3")), ("tokenizer.chat_template", .string("{{ tools }}"))])
      .write(to: model)
    #expect(GGUFMetadata.chatTemplate(path: model.path) == .some("{{ tools }}"))

    let audio = dir.appendingPathComponent("mmproj-audio.gguf")
    try gguf([("clip.has_vision_encoder", .bool(true)), ("clip.has_audio_encoder", .bool(true))])
      .write(to: audio)
    #expect(GGUFMetadata.hasAudioEncoder(path: audio.path) == true)

    let vision = dir.appendingPathComponent("mmproj-vision.gguf")
    try gguf([("clip.has_vision_encoder", .bool(true))]).write(to: vision)
    #expect(GGUFMetadata.hasAudioEncoder(path: vision.path) == false)
    #expect(GGUFMetadata.chatTemplate(path: vision.path) == .some(nil))

    let junk = dir.appendingPathComponent("junk.gguf")
    try Data("not a gguf".utf8).write(to: junk)
    #expect(GGUFMetadata.hasAudioEncoder(path: junk.path) == nil)
  }

  // MARK: - A minimal GGUF v3 header

  private enum Value {
    case string(String)
    case bool(Bool)
  }

  private func gguf(_ pairs: [(String, Value)]) -> Data {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    func append(_ string: String) {
      append(UInt64(string.utf8.count))
      data.append(contentsOf: Array(string.utf8))
    }
    append(UInt32(0x4655_4747))  // "GGUF"
    append(UInt32(3))
    append(UInt64(0))  // tensors
    append(UInt64(pairs.count))
    for (key, value) in pairs {
      append(key)
      switch value {
      case .string(let string):
        append(UInt32(8))
        append(string)
      case .bool(let bool):
        append(UInt32(7))
        append(UInt8(bool ? 1 : 0))
      }
    }
    return data
  }
}
