import SwiftUI

/// One question of the Try screen, as a form section: its ID, type, instructions and
/// the criteria its type takes.
struct QuestionEditor: View {
  @Binding var question: DecisionQuestion
  let remove: () -> Void

  var body: some View {
    Section {
      TextField("ID", text: $question.key)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .accessibilityIdentifier("questionKey")
      Picker("Type", selection: $question.kind) {
        ForEach(DecisionQuestion.Kind.allCases) { Text($0.label).tag($0) }
      }
      .pickerStyle(.segmented)
      TextField("Question", text: $question.instructions, axis: .vertical)
      switch question.kind {
      case .choice: options
      case .score: levels
      case .noul:
        TextField("What yes means (optional)", text: $question.yes, axis: .vertical)
        TextField("What no means (optional)", text: $question.no, axis: .vertical)
      }
    } header: {
      HStack {
        Text(question.key.isEmpty ? "Question" : question.key)
        Spacer()
        Button("Remove", role: .destructive, action: remove)
          .font(.caption)
          .textCase(nil)
      }
    } footer: {
      Text(footer)
    }
  }

  @ViewBuilder private var options: some View {
    ForEach($question.options) { $option in
      VStack(alignment: .leading, spacing: 4) {
        TextField("Option", text: $option.name)
          .textInputAutocapitalization(.never)
        TextField("Description (optional)", text: $option.description, axis: .vertical)
          .font(.caption)
      }
    }
    .onDelete { question.options.remove(atOffsets: $0) }
    Button("Add option", systemImage: "plus") { question.options.append(DecisionOption(name: "")) }
  }

  @ViewBuilder private var levels: some View {
    ForEach(Array($question.levels.enumerated()), id: \.element.id) { index, $level in
      HStack {
        Text("\(index)").monospacedDigit().foregroundStyle(.secondary)
        TextField("Level \(index)", text: $level.text)
      }
    }
    .onDelete { question.levels.remove(atOffsets: $0) }
    Button("Add level", systemImage: "plus") { question.levels.append(DecisionLevel(text: "")) }
      .disabled(question.levels.count >= DecisionQuestion.levelRange.upperBound)
  }

  private var footer: String {
    switch question.kind {
    case .choice: "The answer is the most likely option, with each option's probability."
    case .score: "Lowest level first, 2 to 10 levels. The answer is the expected level."
    case .noul: "The answer is the probability of yes."
    }
  }
}
