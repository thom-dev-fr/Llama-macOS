import Foundation

/// Keeps the last request written on each model's Try screen, so it is there the next
/// time. One draft per model, without images and without past answers: decisions are
/// not conversations, and have no history.
extension DecisionDraft {
  /// The model's draft, or the example for a model that has none yet.
  static func saved(for modelId: String) -> DecisionDraft {
    guard
      let data = UserDefaults.standard.data(forKey: key(modelId)),
      let draft = try? JSONDecoder().decode(DecisionDraft.self, from: data)
    else { return .example }
    return draft
  }

  func save(for modelId: String) {
    guard let data = try? JSONEncoder().encode(self) else { return }
    UserDefaults.standard.set(data, forKey: Self.key(modelId))
  }

  /// Forgets the draft, when its model is deleted.
  static func remove(for modelId: String) {
    UserDefaults.standard.removeObject(forKey: key(modelId))
  }

  private static func key(_ modelId: String) -> String { "decisionDraft.\(modelId)" }
}
