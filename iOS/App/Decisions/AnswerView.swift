import SwiftUI

/// A decision model's answer to one question, drawn for its type: every option's
/// probability for a choice, the expected level for a score, the probability of yes.
struct AnswerView: View {
  let key: String
  let answer: DecisionAnswer

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      switch answer {
      case .choice(let choice, let probabilities, let confidence):
        headline(choice, detail: "Confidence \(percent(confidence))")
        ForEach(probabilities.sorted { $0.value > $1.value }, id: \.key) { option, probability in
          bar(option, probability, highlighted: option == choice)
        }
      case .score(let score, let legend, let probabilities, let confidence):
        let nearest = Int(score.rounded())
        headline(
          [score.formatted(.number.precision(.fractionLength(1))), legend[nearest]]
            .compactMap { $0 }.joined(separator: " — "),
          detail: "Confidence \(percent(confidence))")
        ForEach(probabilities.keys.sorted(), id: \.self) { level in
          bar("\(level) · \(legend[level] ?? "")", probabilities[level] ?? 0, highlighted: level == nearest)
        }
      case .noul(let yes):
        headline(yes >= 0.5 ? "Yes" : "No", detail: "Yes at \(percent(yes))")
        bar("Yes", yes, highlighted: yes >= 0.5)
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("answer-\(key)")
  }

  private func headline(_ title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(key).font(.caption).foregroundStyle(.secondary)
      Text(title).font(.headline)
      Text(detail).font(.caption).foregroundStyle(.secondary)
    }
  }

  private func bar(_ label: String, _ probability: Double, highlighted: Bool) -> some View {
    ProgressView(value: min(max(probability, 0), 1)) {
      HStack {
        Text(label).lineLimit(2)
        Spacer()
        Text(percent(probability)).monospacedDigit()
      }
      .font(.subheadline)
    }
    .tint(highlighted ? .accentColor : .secondary)
  }

  private func percent(_ value: Double) -> String {
    value.formatted(.percent.precision(.fractionLength(0...1)))
  }
}
