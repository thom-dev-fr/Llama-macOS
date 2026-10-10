import LlamaCore
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The Try screen of a decision model: a state and typed questions about it, with the
/// model's answers on a page of their own. Decision models don't chat, so this takes
/// the WebUI's place for them. Requests go to the embedded server, which loads the model when another one
/// is in memory.
struct DecisionView: View {
  let model: Model
  let engine: EngineController
  /// The model has an image projector, so the state can include images.
  let readsImages: Bool
  @State private var draft: DecisionDraft
  @State private var images: [DecisionImage] = []
  @State private var running = false
  @State private var error: String?
  /// The last answers, with the questions as they were asked.
  @State private var exchange: DecisionClient.Exchange?
  @State private var asked: [DecisionQuestion] = []
  @State private var showsAnswers = false
  @State private var choosingSource = false
  @State private var showsPhotos = false
  @State private var showsCamera = false
  @State private var showsFiles = false
  @State private var photoItems: [PhotosPickerItem] = []
  @State private var imageTask: Task<Void, Never>?
  @Environment(\.dismiss) private var dismiss

  init(model: Model, engine: EngineController, readsImages: Bool) {
    self.model = model
    self.engine = engine
    self.readsImages = readsImages
    _draft = State(initialValue: .saved(for: model.id))
  }

  var body: some View {
    NavigationStack {
      Form {
        stateSection
        ForEach($draft.questions) { $question in
          QuestionEditor(question: $question) {
            draft.questions.removeAll { $0.id == question.id }
          }
        }
        Section {
          Button("Add question", systemImage: "plus", action: addQuestion)
            .accessibilityIdentifier("addQuestion")
        }
      }
      // Always in reach: the form grows with every question.
      .safeAreaInset(edge: .bottom) { runBar }
      .navigationDestination(isPresented: $showsAnswers) {
        if let exchange { AnswersPage(exchange: exchange, asked: asked) }
      }
      .navigationTitle(ModelIdParser.plainName(model.id, showTags: true))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } }
        ToolbarItem(placement: .topBarTrailing) { moreMenu }
      }
    }
    .onChange(of: draft) { draft.save(for: model.id) }
    .onDisappear { cancelImageImport() }
    .confirmationDialog("Add an image", isPresented: $choosingSource, titleVisibility: .hidden) {
      Button("Photo Library") { showsPhotos = true }
      if UIImagePickerController.isSourceTypeAvailable(.camera) {
        Button("Take Photo") { showsCamera = true }
      }
      Button("Choose File") { showsFiles = true }
    }
    .photosPicker(isPresented: $showsPhotos, selection: $photoItems, matching: .images)
    .onChange(of: photoItems) { addPhotos() }
    .fullScreenCover(isPresented: $showsCamera) {
      Camera { image in
        if let image { add(image) }
      }
      .ignoresSafeArea()
    }
    .fileImporter(
      isPresented: $showsFiles, allowedContentTypes: [.image], allowsMultipleSelection: true
    ) { result in
      addFiles(result)
    }
  }

  // MARK: - Sections

  private var stateSection: some View {
    Section {
      TextField("What the questions are about", text: $draft.state, axis: .vertical)
        .lineLimit(3...10)
        .accessibilityIdentifier("decisionState")
      if !images.isEmpty {
        ScrollView(.horizontal) {
          HStack {
            ForEach(images) { image in
              Image(uiImage: image.thumbnail)
                .resizable().scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(.rect(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                  Button("Remove", systemImage: "xmark.circle.fill") {
                    images.removeAll { $0.id == image.id }
                  }
                  .labelStyle(.iconOnly)
                  .foregroundStyle(.white, .black.opacity(0.6))
                  .padding(2)
                }
            }
          }
        }
      }
      if readsImages {
        Button("Add image", systemImage: "photo.badge.plus") { choosingSource = true }
          .buttonStyle(.borderless)
          .disabled(imageTask != nil)
        if imageTask != nil { ProgressView("Preparing images…") }
      }
    } header: {
      Text("State")
    } footer: {
      Text(readsImages
        ? "Text, images or both. Each question is asked about it."
        : "Each question is asked about it. This model doesn't read images.")
    }
  }

  private var runBar: some View {
    let problem = draft.problem(imageCount: images.count)
    return VStack(spacing: 8) {
      if let error {
        Text(error).foregroundStyle(.red).accessibilityIdentifier("decisionError")
      } else if let problem {
        Text(problem).foregroundStyle(.secondary)
      }
      HStack {
        Button(action: run) {
          runLabel.frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.glassProminent)
        .disabled(problem != nil || imageTask != nil)
        // While running, the button shows the progress and ignores taps, but keeps its
        // look: `disabled` would dim it.
        .allowsHitTesting(!running)
        .accessibilityIdentifier("runDecision")
        // Back to the last answers after editing, without running again.
        if exchange != nil {
          Button { showsAnswers = true } label: {
            Label("Last Answers", systemImage: "list.bullet.rectangle")
              .labelStyle(.iconOnly)
              .frame(minWidth: 32, minHeight: 32)
          }
          .buttonStyle(.glass)
          .accessibilityIdentifier("showAnswers")
        }
      }
    }
    .font(.footnote)
    .multilineTextAlignment(.center)
    .padding(.horizontal)
    .padding(.bottom, 8)
  }

  @ViewBuilder private var runLabel: some View {
    if running {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small).tint(.white)
        // The engine follows the swap: until it reports this model, it's loading.
        Text(engine.loadedModel == model.id ? "Computing…" : "Loading the model…")
      }
    } else {
      Label("Run", systemImage: "play.fill")
    }
  }

  private var moreMenu: some View {
    Menu("More", systemImage: "ellipsis") {
      Button("Reset to Example", systemImage: "arrow.counterclockwise") {
        cancelImageImport()
        draft = .example
        images = []
      }
    }
    .accessibilityIdentifier("decisionMore")
  }

  // MARK: - Actions

  private func addQuestion() {
    let keys = Set(draft.questions.map(\.key))
    let key = (1...).lazy.map { "question\($0)" }.first { !keys.contains($0) }!
    draft.questions.append(DecisionQuestion(
      key: key, kind: .choice, instructions: "",
      options: [DecisionOption(name: ""), DecisionOption(name: "")]))
  }

  private func run() {
    error = nil
    running = true
    let draft = draft
    let jpegImages = images.map(\.jpeg)
    Task {
      defer { running = false }
      do {
        let answered = try await DecisionClient.run(draft, model: model.id, images: jpegImages, on: engine.url)
        asked = draft.questions
        exchange = answered
        showsAnswers = true
      } catch {
        self.error = error.localizedDescription
      }
    }
  }

  // MARK: - Images

  private func add(_ image: UIImage) {
    importImages {
      await DecisionImage.prepare(image).map { [$0] } ?? []
    }
  }

  private func cancelImageImport() {
    imageTask?.cancel()
    imageTask = nil
  }

  private func importImages(_ prepare: @escaping @MainActor () async -> [DecisionImage]) {
    cancelImageImport()
    imageTask = Task {
      let prepared = await prepare()
      guard !Task.isCancelled else { return }
      images.append(contentsOf: prepared)
      imageTask = nil
    }
  }

  private func addPhotos() {
    let items = photoItems
    guard !items.isEmpty else { return }
    photoItems = []
    importImages {
      var prepared: [DecisionImage] = []
      for item in items {
        guard !Task.isCancelled else { return [] }
        if let data = try? await item.loadTransferable(type: Data.self),
          let picked = await DecisionImage.prepare(data) {
          prepared.append(picked)
        }
      }
      return prepared
    }
  }

  private func addFiles(_ result: Result<[URL], Error>) {
    guard case .success(let urls) = result else { return }
    importImages {
      var prepared: [DecisionImage] = []
      for url in urls {
        guard !Task.isCancelled else { return [] }
        if let data = await AttachmentFiles.read(url), let picked = await DecisionImage.prepare(data) {
          prepared.append(picked)
        }
      }
      return prepared
    }
  }
}

/// An image added to the state, as JPEG, which every projector reads; HEIC and the
/// rest are converted. The server caps an image's tokens, so it isn't resized here.
nonisolated private struct DecisionImage: Identifiable, Sendable {
  let id = UUID()
  let jpeg: Data
  let thumbnail: UIImage

  @concurrent
  static func prepare(_ image: UIImage) async -> DecisionImage? {
    autoreleasepool {
      guard let jpeg = image.jpegData(compressionQuality: 0.9) else { return nil }
      return DecisionImage(jpeg: jpeg)
    }
  }

  @concurrent
  static func prepare(_ data: Data) async -> DecisionImage? {
    autoreleasepool {
      // Preserve JPEGs; other formats are converted off the UI actor.
      if let source = CGImageSourceCreateWithData(data as CFData, nil),
        (CGImageSourceGetType(source) as String?) == UTType.jpeg.identifier {
        return DecisionImage(jpeg: data)
      }
      guard let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.9) else { return nil }
      return DecisionImage(jpeg: jpeg)
    }
  }

  private init?(jpeg: Data) {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 128,
        kCGImageSourceShouldCacheImmediately: true,
      ] as CFDictionary)
    else { return nil }
    self.jpeg = jpeg
    self.thumbnail = UIImage(cgImage: thumbnail)
  }
}

/// The answers of a run, one per question in the order they were asked, and how long
/// the run took. Pushed on the Try screen, so a long form doesn't bury them.
private struct AnswersPage: View {
  let exchange: DecisionClient.Exchange
  let asked: [DecisionQuestion]

  var body: some View {
    List {
      Section {
        ForEach(asked) { question in
          if let answer = exchange.result.answers[question.key.trimmingCharacters(in: .whitespacesAndNewlines)] {
            AnswerView(key: question.key, answer: answer)
          }
        }
      } footer: {
        Text("Probabilities aren't guaranteed to be calibrated for your data.")
      }
      Section("Performance") {
        TimingsView(timings: exchange.timings, usage: exchange.result.usage)
      }
    }
    .navigationTitle("Answers")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu("Copy", systemImage: "doc.on.doc") {
          Button("Copy Request JSON") { copy(exchange.request) }
          Button("Copy Response JSON") { copy(exchange.response) }
        }
      }
    }
  }

  /// Pretty-printed, so it reads as the request a developer would write.
  private func copy(_ data: Data) {
    Task {
      if let text = await DecisionClient.prettyPrinted(data) { UIPasteboard.general.string = text }
    }
  }
}

/// How long the last request took: the input and its throughput, then the durations,
/// each last on its row so they add up to the total: the engine's compute, the model
/// load when it had to swap one in, and the whole request.
private struct TimingsView: View {
  let timings: DecisionClient.Timings
  let usage: DecisionResult.Usage?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      // A load under 50 ms means the model was already in memory.
      if let load = timings.load, load >= 50 {
        row("Model load", [duration(load)])
      }
      if let usage {
        row("Usage", ["\(usage.inputTokens) tokens", rate(usage.inputTokens, timings.compute)])
      }
      // No output row: a decision model reads its answers from one pass over the
      // input, so the compute is all input.
      if let compute = timings.compute {
        row("Compute", [duration(compute)])
          .accessibilityIdentifier("decisionCompute")
      }
      // row("Total", [duration(timings.total)])
    }
    .font(.subheadline)
    .padding(.vertical, 4)
  }

  private func row(_ title: String, _ values: [String?]) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title).foregroundStyle(.secondary)
      Spacer()
      Text(values.compactMap { $0 }.joined(separator: " · "))
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
    }
    .accessibilityElement(children: .combine)
  }

  private func rate(_ tokens: Int?, _ ms: Double?) -> String? {
    guard let tokens, let ms, ms > 0 else { return nil }
    return "\((Double(tokens) / (ms / 1000)).formatted(.number.precision(.fractionLength(0)))) tok/s"
  }

  private func duration(_ ms: Double) -> String {
    ms < 1000
      ? "\(ms.formatted(.number.precision(.fractionLength(0)))) ms"
      : "\((ms / 1000).formatted(.number.precision(.fractionLength(2)))) s"
  }
}
