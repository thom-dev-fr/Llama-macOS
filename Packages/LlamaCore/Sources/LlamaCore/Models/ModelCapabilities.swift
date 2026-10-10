import Foundation

extension Model {
  /// What a model does beyond text in, text out, as its GGUF headers tell it.
  /// Image input isn't here: it follows from the mmproj sidecar alone (see
  /// `hasVisionSupport`).
  public struct Capabilities: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Takes audio input: the projector carries an audio encoder.
    public static let audio = Capabilities(rawValue: 1 << 0)
    /// Thinks before answering, in a block llama-server returns as
    /// `reasoning_content`.
    public static let reasoning = Capabilities(rawValue: 1 << 1)
    /// Calls tools the request declares.
    public static let tools = Capabilities(rawValue: 1 << 2)

    /// Template markers of a thinking phase: the tags themselves (`<think>`,
    /// Seed's `<seed:think>`), Qwen's and Gemma's `enable_thinking` switch, the
    /// `reasoning_content` field templates replay past thoughts from, and
    /// gpt-oss's `reasoning_effort`.
    private static let reasoningMarkers = [
      "think>", "enable_thinking", "reasoning_content", "reasoning_effort",
    ]

    /// Reads the capabilities from the chat template and the projector header.
    ///
    /// The template decides what llama-server can do with a conversation: one
    /// that never reads the `tools` variable drops a request's tools, and one
    /// without a thinking marker has no phase to switch. That makes a substring
    /// match a fair proxy for llama.cpp's own probe, which renders the template
    /// with and without each feature and compares.
    public init(chatTemplate: String?, hasAudioEncoder: Bool) {
      self = []
      if hasAudioEncoder { insert(.audio) }
      guard let chatTemplate else { return }
      if Self.reasoningMarkers.contains(where: chatTemplate.contains) { insert(.reasoning) }
      if chatTemplate.contains("tools") { insert(.tools) }
    }
  }
}
