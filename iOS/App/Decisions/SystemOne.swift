import Foundation

/// A `/v1/systemone` request as the Try screen edits it: a state and typed questions
/// about it. Codable so it can be kept as the model's draft; images stay out of it.
///
/// The API is llama.cpp's TypeSafe-compatible System One API (tools/server/README.md).
nonisolated struct DecisionDraft: Sendable, Codable, Equatable {
  var state: String
  var questions: [DecisionQuestion]

  /// The request from the llama.cpp server README: a customer message, routed, read
  /// for anger and rated for urgency. Shows each question type at once.
  static let example = DecisionDraft(
    state: "Customer message: I was charged twice for my order last week and nobody has replied.",
    questions: [
      DecisionQuestion(
        key: "route", kind: .choice, instructions: "Which team should handle this?",
        options: ["billing", "shipping", "technical"].map { DecisionOption(name: $0) }),
      DecisionQuestion(key: "angry", kind: .noul, instructions: "Is the customer angry?"),
      DecisionQuestion(
        key: "urgency", kind: .score, instructions: "How urgent is this?",
        levels: ["can wait", "this week", "today", "right now"].map { DecisionLevel(text: $0) }),
    ])

  /// Why the request can't be sent yet, or nil when it can. Mirrors the server's own
  /// checks, so a request it would refuse with a 400 never leaves the screen.
  func problem(imageCount: Int) -> String? {
    if state.isBlank && imageCount == 0 { return "Describe the state, or add an image." }
    if questions.isEmpty { return "Add a question." }
    let keys = questions.map { $0.key.trimmed }
    if keys.contains("") { return "Every question needs an ID." }
    if Set(keys).count != keys.count { return "Question IDs must be different." }
    return questions.lazy.compactMap(\.problem).first
  }

  /// The request body for `model`, with `images` as data URLs.
  func body(model: String, images: [Data]) -> [String: Any] {
    var body: [String: Any] = [
      "model": model,
      "questions": Dictionary(uniqueKeysWithValues: questions.map { ($0.key.trimmed, $0.json) }),
    ]
    // Empty rather than null when images carry the request: only the lfm2-d1 models
    // accept a null state.
    body["state"] = state.isBlank ? "" : state
    if !images.isEmpty {
      body["files"] = images.map { "data:image/jpeg;base64,\($0.base64EncodedString())" }
    }
    return body
  }
}

/// One typed question. Every type's criteria are kept, so switching type and back
/// loses nothing.
nonisolated struct DecisionQuestion: Sendable, Codable, Equatable, Identifiable {
  enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// One option among several.
    case choice
    /// A level on a scale of 2 to 10.
    case score
    /// Yes or no, as a probability of yes.
    case noul

    var id: Self { self }

    var label: String {
      switch self {
      case .choice: "Choice"
      case .score: "Score"
      case .noul: "Yes / No"
      }
    }
  }

  static let levelRange = 2...10

  var id = UUID()
  /// The question's ID in the request and the response.
  var key: String
  var kind: Kind
  var instructions: String
  var options: [DecisionOption] = []
  /// Level descriptions, lowest first.
  var levels: [DecisionLevel] = []
  /// Optional descriptions of what yes and no mean.
  var yes = ""
  var no = ""

  var problem: String? {
    let name = key.trimmed
    if instructions.isBlank { return "“\(name)” needs instructions." }
    switch kind {
    case .choice:
      let names = options.map { $0.name.trimmed }
      if names.count < 2 { return "“\(name)” needs at least 2 options." }
      if names.contains("") { return "Every option of “\(name)” needs a name." }
      if Set(names).count != names.count { return "The options of “\(name)” must be different." }
    case .score:
      if !Self.levelRange.contains(levels.count) { return "“\(name)” needs 2 to 10 levels." }
      if levels.contains(where: \.text.isBlank) { return "Every level of “\(name)” needs a description." }
    case .noul:
      break
    }
    return nil
  }

  fileprivate var json: [String: Any] {
    var question: [String: Any] = ["type": kind.rawValue, "instructions": instructions]
    switch kind {
    case .choice:
      question["criteria"] = Dictionary(uniqueKeysWithValues: options.map { option in
        (option.name.trimmed, option.description.isBlank ? NSNull() : option.description as Any)
      })
    case .score:
      question["criteria"] = levels.map(\.text)
    case .noul:
      // Each description is optional; the server reads a missing one as none.
      let criteria = [("true", yes), ("false", no)].filter { !$0.1.isBlank }
      if !criteria.isEmpty { question["criteria"] = Dictionary(uniqueKeysWithValues: criteria) }
    }
    return question
  }
}

/// An option of a choice question, with an optional description.
nonisolated struct DecisionOption: Sendable, Codable, Equatable, Identifiable {
  var id = UUID()
  var name: String
  var description = ""
}

/// A level of a score question.
nonisolated struct DecisionLevel: Sendable, Codable, Equatable, Identifiable {
  var id = UUID()
  var text: String
}

/// The server's answer to every question, by question ID.
nonisolated struct DecisionResult: Sendable, Decodable {
  let model: String?
  let answers: [String: DecisionAnswer]
  let usage: Usage?

  struct Usage: Decodable, Sendable {
    let inputTokens: Int
    /// Always 0 for now: a decision model reads its answers from one pass over the
    /// input, without generating.
    let outputTokens: Int?

    private enum CodingKeys: String, CodingKey {
      case inputTokens = "input_tokens"
      case outputTokens = "output_tokens"
    }
  }
}

nonisolated enum DecisionAnswer: Sendable, Decodable {
  /// Probabilities sum to 1. Confidence is 0 when every option is equally likely.
  case choice(choice: String, probabilities: [String: Double], confidence: Double)
  /// The expected level index, weighted by probability, so it can fall between levels.
  case score(score: Double, legend: [Int: String], probabilities: [Int: Double], confidence: Double)
  /// The probability that the answer is yes.
  case noul(Double)

  private enum CodingKeys: String, CodingKey {
    case type, choice, probabilities, confidence, score, legend, noul
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .type) {
    case "choice":
      self = .choice(
        choice: try c.decode(String.self, forKey: .choice),
        probabilities: try c.decode([String: Double].self, forKey: .probabilities),
        confidence: try c.decode(Double.self, forKey: .confidence))
    case "score":
      // Level indexes come as string keys ("0", "1", ...).
      let legend = try c.decode([String: String].self, forKey: .legend)
      let probabilities = try c.decode([String: Double].self, forKey: .probabilities)
      self = .score(
        score: try c.decode(Double.self, forKey: .score),
        legend: Dictionary(uniqueKeysWithValues: legend.compactMap { k, v in Int(k).map { ($0, v) } }),
        probabilities: Dictionary(uniqueKeysWithValues: probabilities.compactMap { k, v in Int(k).map { ($0, v) } }),
        confidence: try c.decode(Double.self, forKey: .confidence))
    case "noul":
      self = .noul(try c.decode(Double.self, forKey: .noul))
    case let other:
      throw DecodingError.dataCorruptedError(
        forKey: .type, in: c, debugDescription: "Unknown answer type \(other)")
    }
  }
}

nonisolated extension String {
  fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
  fileprivate var isBlank: Bool { trimmed.isEmpty }
}
