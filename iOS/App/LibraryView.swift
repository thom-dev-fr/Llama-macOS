import LlamaCore
import SwiftUI

/// Native screen for models and the engine. Conversations happen in the WebUI, which
/// opens full screen from a model's Chat button or the engine bar.
struct LibraryView: View {
  @Bindable var library: ModelLibrary
  let engine: EngineController
  let chat: ChatController
  /// The WebUI on screen, zoomed from the button that opened it.
  @State private var chatting: ChatSource?
  /// A chat asked for while the last one is still closing, shown once it has.
  @State private var queuedChat: ChatSource?
  /// The decision model whose Try screen is on screen.
  @State private var trying: Model?
  @State private var showAddRepo = false
  @State private var showSettings = false
  /// Repo being resolved into a download.
  @State private var resolving: String?
  /// Resolved model waiting for the user to confirm its download.
  @State private var pending: Model?
  /// Installed model waiting for the user to confirm its deletion.
  @State private var deleting: Model?
  @Namespace private var transition

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          Text(summary)
            .font(.subheadline).foregroundStyle(.secondary)
            .padding(.horizontal, 4)
          errors
          downloads
          if library.isLoading {
            ProgressView("Loading models…").padding()
          } else {
            installed
          }
          recommended
        }
        .padding(.horizontal)
        .padding(.bottom)
      }
      .swipeActionsContainerIfAvailable()
      .background(Color(.systemGroupedBackground))
      .navigationTitle("Models")
      .toolbar { toolbar }
      // Always in reach: what the engine holds, and the way back to the chat.
      .safeAreaInset(edge: .bottom) { engineBar }
      .fullScreenCover(item: $chatting) { source in
        ChatScreen(chat: chat)
          .navigationTransition(.zoom(sourceID: source.id, in: transition))
      }
      .sheet(item: $trying) { model in
        DecisionView(model: model, engine: engine, readsImages: library.readsImages(model))
      }
      .sheet(isPresented: $showSettings) {
        SettingsView(library: library)
      }
      .sheet(isPresented: $showAddRepo) {
        AddRepoSheet { repo, quant in resolve(repo: repo, quant: quant) }
      }
      .itemAlert("Download this model?", item: $pending) { model in
        Button("Download") { library.install(model) }
        Button("Cancel", role: .cancel) {}
      } message: { model in
        Text(confirmationMessage(for: model))
      }
      .itemConfirmationDialog("Delete this model?", item: $deleting) { model in
        Button("Delete \(ModelLibrary.size(model.fileSize))", role: .destructive) { delete(model) }
          .accessibilityIdentifier("confirmDelete")
      } message: { model in
        Text("\(ModelIdParser.plainName(model.id, showTags: true)). Conversations stay. The model can be downloaded again.")
      }
      .onOpenURL { url in
        guard case .install(let repo, let quant) = LlamaURL.parse(url) else { return }
        resolve(repo: repo, quant: quant)
      }
      .onChange(of: chat.isShown) { _, shown in
        guard !shown, let queued = queuedChat else { return }
        queuedChat = nil
        chatting = queued
      }
      .task { await library.loadSuggestions() }
      .refreshable { await refresh() }
    }
  }

  private var summary: String {
    let count = library.installed.count
    return [
      count == 1 ? "1 installed" : "\(count) installed",
      "\(ModelLibrary.size(library.installedBytes)) used",
      "\(ModelLibrary.size(library.availableBytes)) free",
    ].joined(separator: " · ")
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      Button("Settings", systemImage: "gearshape") { showSettings = true }
        .accessibilityIdentifier("settings")
    }
    if #available(iOS 27, *) {
      // Never pushed into the overflow menu: adding a model is the screen's action.
      ToolbarItem(placement: .topBarPinnedTrailing) { addButton }
      ToolbarOverflowMenu { moreActions }
    } else {
      ToolbarItem(placement: .topBarTrailing) {
        Menu("More", systemImage: "ellipsis") { moreActions }
      }
      ToolbarItem(placement: .primaryAction) { addButton }
    }
  }

  private var addButton: some View {
    Button("Add from Hugging Face", systemImage: "plus") { showAddRepo = true }
      .buttonStyle(.glassProminent)
      .accessibilityIdentifier("addRepo")
      .disabled(resolving != nil)
  }

  @ViewBuilder private var moreActions: some View {
    Link(destination: Self.browseCatalogURL) {
      Label("Browse All Models", systemImage: "square.grid.2x2")
    }
    Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
  }

  // MARK: - Sections

  /// At the top, where they are seen: a failure to resolve, install or start.
  @ViewBuilder private var errors: some View {
    ForEach([library.error, engine.error].compactMap { $0 }, id: \.self) { error in
      Label(error, systemImage: "exclamationmark.triangle.fill")
        .font(.subheadline)
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityIdentifier("error")
    }
  }

  /// One row per model, downloading or interrupted. Pausing turns the row into
  /// an interrupted one in place rather than moving it to another list.
  @ViewBuilder private var downloads: some View {
    let rows = library.downloads.map(DownloadRow.active) + library.interrupted.map(DownloadRow.interrupted)
    if !rows.isEmpty {
      SectionTitle("Downloading")
      ForEach(rows) { row in
        Group {
          switch row {
          case .active(let download): activeDownload(download)
          case .interrupted(let model): interruptedDownload(model)
          }
        }
        .card()
      }
    }
  }

  private func activeDownload(_ download: ModelLibrary.Download) -> some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 8) {
        ModelName(id: download.model.id)
        ProgressView(value: download.fraction)
        Text("\(ModelLibrary.size(download.bytes)) of \(ModelLibrary.size(download.model.fileSize))")
          .font(.footnote).foregroundStyle(.secondary)
          .accessibilityIdentifier("downloadProgress")
      }
      Button("Stop", systemImage: "pause.fill") { library.stopDownload(download.model) }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.large)
    }
  }

  private func interruptedDownload(_ model: Model) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      ModelName(id: model.id)
      Text("Interrupted").font(.footnote).foregroundStyle(.secondary)
      HStack {
        Button("Resume") { library.install(model) }
          .buttonStyle(.bordered)
        Spacer()
        Button("Discard", role: .destructive) { library.discard(model) }
      }
    }
  }

  @ViewBuilder private var installed: some View {
    SectionTitle("Installed")
    if library.installed.isEmpty {
      Text("No models yet. Download a recommended one, or add one from Hugging Face.")
        .foregroundStyle(.secondary)
        .card()
    }
    ForEach(library.installed) { model in
      ModelCard(
        model: model, loaded: engine.loadedModel == model.id, readsImages: library.readsImages(model),
        warning: library.warning(for: model), estimating: library.isEstimating(model),
        context: library.contextTier(for: model), contexts: library.contextTiers(for: model),
        selectContext: { library.setContextTier($0, for: model) },
        open: openAction(for: model), delete: { deleting = model }, transition: transition)
    }
  }

  /// The full catalog on llama.app; its install buttons open `llama://install` links.
  /// `ref` tells the site's analytics the visit comes from this app, as on the Mac.
  private static let browseCatalogURL = URL(string: "https://llama.app/models?ref=llama-ios")!

  @ViewBuilder private var recommended: some View {
    let suggestions = library.visibleSuggestions
    let state = library.suggestionsState
    SectionTitle(suggestions.isEmpty && state == .loaded ? "More models" : "Recommended for this device")
    if suggestions.isEmpty {
      switch state {
      case .loading:
        HStack(spacing: 10) {
          ProgressView()
          Text("Finding models for this device…").foregroundStyle(.secondary)
        }
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("suggestionsLoading")
      case .failed(let message):
        VStack(alignment: .leading, spacing: 10) {
          Label("Couldn't load the recommendations", systemImage: "wifi.exclamationmark")
            .font(.subheadline.weight(.semibold))
          Text(message).font(.footnote).foregroundStyle(.secondary)
          Button("Try Again") { Task { await library.loadSuggestions() } }
            .buttonStyle(.bordered)
        }
        .card()
        .accessibilityIdentifier("suggestionsFailed")
      case .loaded:
        EmptyView()
      }
    }
    ForEach(suggestions, id: \.repo) { suggestion in
      HStack(spacing: 12) {
        ModelTile(logoAsset: suggestion.brandLogoAsset, name: suggestion.brand)
        VStack(alignment: .leading, spacing: 4) {
          ModelName(id: suggestion.repo)
          Text(
            [suggestion.quant, suggestion.sizeLabel, suggestion.hasVision ? "Image input" : nil]
              .compactMap { $0 }.joined(separator: " · ")
          )
          .font(.footnote).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        // The spinner takes the label's place inside the button, so it stays
        // centered where "Get" was and the button keeps its size.
        Button {
          resolve(repo: suggestion.repo, quant: suggestion.quant)
        } label: {
          Text("Get")
            .opacity(resolving == suggestion.repo ? 0 : 1)
            .overlay {
              if resolving == suggestion.repo { ProgressView() }
            }
        }
        .buttonStyle(.bordered)
        .disabled(resolving != nil)
        .accessibilityLabel(resolving == suggestion.repo ? "Getting" : "Get")
        .accessibilityIdentifier("suggestion-\(suggestion.repo)")
      }
      .card()
    }
    Link(destination: Self.browseCatalogURL) {
      Label("Browse all models", systemImage: "square.grid.2x2")
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .card()
    .accessibilityIdentifier("browseModels")
  }

  // MARK: - Engine

  /// The loaded model and its memory, with Unload and a way back to the chat; or the
  /// engine starting, or a Start after a failed start.
  private var engineBar: some View {
    HStack(spacing: 10) {
      switch engine.state {
      case .starting, .stopping:
        ProgressView()
        Text("Starting the engine…")
        Spacer()
      case .stopped:
        // Only after a failed start: otherwise the engine runs whenever the app is open.
        Label("Engine stopped", systemImage: "bolt.slash")
        Spacer()
        Button("Start the engine") { engine.start() }
          .accessibilityIdentifier("startServer")
      case .running:
        if let id = engine.loadedModel {
          Image(systemName: "bolt.fill").foregroundStyle(.green)
          (Text(ModelIdParser.plainName(id, showTags: false)).fontWeight(.semibold)
            + Text(loadedMemory.map { " · \($0)" } ?? "").foregroundStyle(.secondary))
            .lineLimit(1)
            .accessibilityIdentifier("loadedModel")
            .accessibilityValue(id)
          Spacer(minLength: 4)
          Button("Unload the model", systemImage: "eject") { Task { await engine.unload() } }
            .labelStyle(.iconOnly)
        } else {
          Image(systemName: "bolt.slash").foregroundStyle(.secondary)
          Text("No model loaded").foregroundStyle(.secondary)
          Spacer()
        }
        Button("Open the chat", systemImage: "bubble.left") { openChat(engine.url, from: "webui") }
          .labelStyle(.iconOnly)
          .matchedTransitionSource(id: "webui", in: transition)
          .accessibilityIdentifier("openWebUI")
      }
    }
    .font(.subheadline)
    .buttonStyle(.borderless)
    .controlSize(.large)
    .padding(.leading, 18)
    .padding(.trailing, 14)
    .frame(minHeight: 52)
    .glassEffect(.regular, in: .capsule)
    .padding(.horizontal)
    .padding(.bottom, 4)
  }

  /// The loaded model's memory at the context it runs with, as its card shows it.
  private var loadedMemory: String? {
    guard let model = library.installed.first(where: { $0.id == engine.loadedModel }),
      let tier = library.contextTier(for: model)
    else { return nil }
    return ModelCard.memory(of: model, at: tier)
  }

  // MARK: - Chat and deletion

  /// Opens the WebUI on `model`, which it then loads, or the Try screen of a decision
  /// model, which can't chat. Nil while the engine can't load it: not running, or no
  /// context fits (see `ModelLibrary.contextTier`).
  private func openAction(for model: Model) -> (() -> Void)? {
    guard engine.state == .running, !engine.isUpdatingPresets,
      library.loadableModels.contains(model.id) else { return nil }
    if model.kind == .decision { return { trying = model } }
    return { openChat(engine.chatURL(model: model.id), from: model.id) }
  }

  private func openChat(_ url: URL, from source: String) {
    chat.open(url)
    if chat.isShown {
      queuedChat = ChatSource(id: source)
    } else {
      chatting = ChatSource(id: source)
    }
  }

  /// The engine holds a loaded model's files open, so it lets go of them first.
  private func delete(_ model: Model) {
    Task {
      if engine.loadedModel == model.id { await engine.unload() }
      library.remove(model)
    }
  }

  private func refresh() async {
    library.refresh()
    await library.loadSuggestions()
  }

  // MARK: - Installing

  private func resolve(repo: String, quant: String?) {
    library.error = nil
    resolving = repo
    Task {
      defer { resolving = nil }
      do {
        let model = try await library.resolve(repo: repo, quant: quant)
        if library.isInstalled(model) {
          library.error = "\(model.displayName) is already installed."
        } else if library.isDownloading(model) {
          library.error = "\(model.displayName) is already downloading."
        } else {
          pending = model
        }
      } catch let error as LocalizedError {
        library.error = [error.errorDescription, error.recoverySuggestion]
          .compactMap { $0 }.joined(separator: " ")
      } catch {
        library.error = error.localizedDescription
      }
    }
  }

  private func confirmationMessage(for model: Model) -> String {
    var lines = [ModelIdParser.plainName(model.id, showTags: true)]
    let size = model.fileSize > 0 ? ModelLibrary.size(model.fileSize) : "unknown size"
    lines.append(model.hasVisionSupport ? "\(size), image projector included." : "\(size).")
    if let warning = library.warning(for: model) { lines.append(warning) }
    if !library.allowCellular { lines.append("Downloads use Wi-Fi only.") }
    return lines.joined(separator: "\n")
  }
}

/// A row of the Downloading section. Its id is its own, apart from the installed
/// row the same model gets once it lands: the lazy stack would otherwise take
/// one for the other and keep showing a stale row.
private enum DownloadRow: Identifiable {
  case active(ModelLibrary.Download)
  case interrupted(Model)

  var id: String {
    switch self {
    case .active(let download): "download-\(download.model.id)"
    case .interrupted(let model): "download-\(model.id)"
    }
  }
}

/// What the chat zooms from: a model's Chat button, or the engine bar's.
private struct ChatSource: Identifiable {
  let id: String
}

// MARK: - Cards

private struct SectionTitle: View {
  let title: String
  init(_ title: String) { self.title = title }

  var body: some View {
    Text(title)
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.leading, 16)
      .padding(.top, 10)
      .accessibilityAddTraits(.isHeader)
  }
}

/// A model's name as the Mac shows it: org when not the default, name, size, tags, quant.
private struct ModelName: View {
  let id: String

  var body: some View {
    Text(ModelIdParser.plainName(id, showTags: true)).font(.headline)
  }
}

private extension View {
  /// A rounded card on the grouped background, as the list's rows.
  func card() -> some View {
    padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
  }
}

/// The brand logo from LlamaCore's shared catalog, as on the Mac, or the name's
/// initial when the brand has no mark.
private struct ModelTile: View {
  let logoAsset: String?
  let name: String

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.9))
      Group {
        if let logoAsset {
          // Template images: the tile tints them, like the letter.
          Image(logoAsset, bundle: ModelLogos.bundle)
            .resizable()
            .scaledToFit()
            .padding(10)
        } else {
          Text(name.prefix(1).uppercased())
            .font(.title3.weight(.bold))
        }
      }
      .foregroundStyle(Color(.systemBackground))
    }
    .frame(width: 44, height: 44)
    .accessibilityHidden(true)
  }
}

private struct ModelCard: View {
  let model: Model
  let loaded: Bool
  let readsImages: Bool
  let warning: String?
  let estimating: Bool
  let context: ContextTier?
  /// Sizes that fit this device. Empty when none is estimated to fit, and the
  /// model runs at 4K anyway.
  let contexts: [ContextTier]
  let selectContext: @MainActor @Sendable (ContextTier) -> Void
  /// Chat, or Try for a decision model. Nil while the model can't be loaded.
  let open: (() -> Void)?
  let delete: () -> Void
  let transition: Namespace.ID
  @Environment(\.dynamicTypeSize) private var typeSize

  /// Side by side, or stacked at the accessibility text sizes, where a row would clip.
  private var layout: AnyLayout {
    typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
      : AnyLayout(HStackLayout(spacing: 12))
  }

  var body: some View {
    let parsed = ModelIdParser.parse(model.id)
    VStack(alignment: .leading, spacing: 12) {
      layout {
        tile(parsed)
        VStack(alignment: .leading, spacing: 2) {
          Text([(parsed.displayOrg.map { $0 + "/" } ?? "") + parsed.name, parsed.params]
            .compactMap { $0 }.joined(separator: " "))
            .font(.headline)
          Text([parsed.quant, ModelLibrary.size(model.fileSize)].compactMap { $0 }.joined(separator: " · "))
            .font(.subheadline).foregroundStyle(.secondary)
        }
        if !typeSize.isAccessibilitySize { Spacer(minLength: 4) }
        openButton
      }
      if hasChips {
        chips
        // Sets what the model is apart from what running it costs.
        if estimating || context != nil { Divider().opacity(0.6) }
      }
      if estimating {
        Label("Measuring memory…", systemImage: "hourglass")
          .font(.footnote).foregroundStyle(.secondary)
      } else if let context {
        memory(at: context)
      }
      if let warning {
        Label(warning, systemImage: "exclamationmark.triangle.fill")
          .font(.footnote).foregroundStyle(.orange)
      }
    }
    .card()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("installed-\(model.id)")
    // The card itself as the context menu's preview. Without a shape, the preview
    // lifted the glass button alone and the rest of the card vanished while it showed.
    .contentShape(.contextMenuPreview, .rect(cornerRadius: 26))
    .swipeActions {
      // Not the destructive role: the row would go before the user confirms.
      Button("Delete", systemImage: "trash", action: delete)
        .tint(.red)
    }
    .contextMenu {
      if model.kind == .decision {
        Button("Try Model", systemImage: "checklist") { open?() }
          .disabled(open == nil)
      } else {
        Button("Chat with Model", systemImage: "bubble.left") { open?() }
          .disabled(open == nil)
      }
      Button("Delete", systemImage: "trash", role: .destructive, action: delete)
      if let url = URL(string: "https://huggingface.co/\(model.idBase)") {
        Link(destination: url) { Label("View on Hugging Face", systemImage: "arrow.up.right") }
      }
    }
  }

  /// A checklist for a decision model, else the brand logo or the model's initial.
  @ViewBuilder private func tile(_ parsed: ModelIdParser.Parsed) -> some View {
    if model.kind == .decision {
      ZStack {
        RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.18))
        Image(systemName: "checklist").foregroundStyle(.orange)
      }
      .frame(width: 44, height: 44)
      .accessibilityHidden(true)
    } else {
      ModelTile(logoAsset: model.brandLogoAsset, name: parsed.name)
    }
  }

  @ViewBuilder private var openButton: some View {
    if model.kind == .decision {
      Button("Try", systemImage: "checklist") { open?() }
        .buttonStyle(.glass)
        .disabled(open == nil)
        .accessibilityIdentifier("try-\(model.id)")
    } else {
      Button("Chat", systemImage: "bubble.left") { open?() }
        .buttonStyle(.glassProminent)
        .disabled(open == nil)
        .matchedTransitionSource(id: model.id, in: transition)
        .accessibilityIdentifier("chat-\(model.id)")
    }
  }

  private var hasChips: Bool {
    loaded || readsImages || model.kind == .decision
      || !model.capabilities.isDisjoint(with: [.audio, .reasoning, .tools])
  }

  /// What the model is and does, in words and symbols, not color alone: loaded,
  /// inputs beyond text, reasoning, tools, decision.
  private var chips: some View {
    let layout = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
      : AnyLayout(ChipFlow(spacing: 6))
    return layout {
      if loaded {
        Chip("Loaded", systemImage: "bolt.fill", tint: .green)
      }
      if readsImages {
        Chip("Image", systemImage: "eye")
      }
      if model.capabilities.contains(.audio) {
        Chip("Audio", systemImage: "waveform")
      }
      if model.capabilities.contains(.reasoning) {
        Chip("Reasoning", systemImage: "brain")
      }
      if model.capabilities.contains(.tools) {
        Chip("Tools", systemImage: "wrench.and.screwdriver")
      }
      if model.kind == .decision {
        Chip("Decision", systemImage: "checklist", tint: .orange)
      }
    }
  }

  /// Two columns: the context picker, then the RAM footprint it leads to, as a
  /// share of what the device offers. The bar's darker part is the weights, the
  /// lighter one the context, which grows with the pick.
  private func memory(at tier: ContextTier) -> some View {
    let total = Double(model.runtimeMemoryUsageMb(ctxWindowTokens: Double(tier.rawValue)))
    let weights = min(model.weightMemoryMb, total)
    let fit = MemoryFit(usedMb: total, budgetMb: DeviceMemory.budgetMb)
    let columns = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
      : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
    return columns {
      // Models that don't chat run at a fixed context, the longest input they
      // take (see `Model.effectiveCtxTier`), so there is nothing to pick.
      if model.kind == .chat {
        contextPicker(tier)
      } else {
        inputLimit(tier)
      }
      VStack(alignment: .leading, spacing: 6) {
        // One line when it fits; the share goes under the footprint otherwise,
        // as with a long size on a narrow phone.
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .firstTextBaseline) {
            footprint(total)
            Spacer(minLength: 4)
            share(fit)
          }
          VStack(alignment: .leading, spacing: 2) {
            footprint(total)
            share(fit)
          }
        }
        .font(.footnote)
        .lineLimit(1)
        MemoryBar(weightsMb: weights, contextMb: total - weights, fit: fit)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("RAM footprint")
      .accessibilityValue(
        "\(Self.size(mb: total)), \(fit.percent) of the \(Self.size(mb: fit.budgetMb)) this device offers. "
          + "\(fit.label).")
    }
  }

  private func footprint(_ mb: Double) -> some View {
    Text("\(Text("RAM footprint").foregroundStyle(.secondary)) · \(Self.size(mb: mb))")
      .monospacedDigit()
  }

  /// "2% of 7 GB": the share in the fit's color, then what it's a share of.
  private func share(_ fit: MemoryFit) -> some View {
    Text("\(Text(fit.percent).fontWeight(.semibold).foregroundStyle(fit.tint)) of \(Self.size(mb: fit.budgetMb))")
      .foregroundStyle(.secondary)
      .monospacedDigit()
  }

  /// "Max input · 4K tokens", where a chat model has its context picker.
  private func inputLimit(_ context: ContextTier) -> some View {
    Text("\(Text("Max input").foregroundStyle(.secondary)) · \(context.shortLabel.uppercased()) tokens")
      .font(.footnote.weight(.semibold))
      .accessibilityIdentifier("input-limit-\(model.id)")
  }

  private func contextPicker(_ context: ContextTier) -> some View {
    Menu {
      Picker("Context", selection: Binding(get: { context }, set: selectContext)) {
        ForEach(contexts.isEmpty ? [context] : contexts) { tier in
          Text(tier.shortLabel.uppercased()).tag(tier)
        }
      }
    } label: {
      HStack(spacing: 4) {
        Text("\(context.shortLabel.uppercased()) context")
        Image(systemName: "chevron.down").imageScale(.small)
      }
      .font(.footnote.weight(.semibold))
      .padding(.horizontal, 10)
      .frame(minHeight: 28)
      .background(Color(.tertiarySystemFill), in: .capsule)
    }
    .accessibilityLabel("Context")
    .accessibilityValue(context.shortLabel.uppercased())
    .accessibilityIdentifier("context-\(model.id)")
  }

  static func memory(of model: Model, at tier: ContextTier) -> String {
    size(mb: Double(model.runtimeMemoryUsageMb(ctxWindowTokens: Double(tier.rawValue))))
  }

  private static func size(mb: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(mb) << 20, countStyle: .memory)
  }
}

private struct Chip: View {
  let title: String
  let systemImage: String
  var tint: Color = .secondary

  init(_ title: String, systemImage: String, tint: Color = .secondary) {
    self.title = title
    self.systemImage = systemImage
    self.tint = tint
  }

  var body: some View {
    Label(title, systemImage: systemImage)
      .font(.footnote.weight(.semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, 10)
      .frame(minHeight: 28)
      .background(tint.opacity(0.14), in: .capsule)
  }
}

// MARK: - Memory

/// How a model's memory sits within the device's budget: a percent and a color
/// on screen, a word for VoiceOver.
private struct MemoryFit {
  let usedMb: Double
  let budgetMb: Double

  /// Used over budget; above 1 when the model may not load.
  var fraction: Double { budgetMb > 0 ? usedMb / budgetMb : .infinity }

  /// The share as a whole percent, at least 1% so a small model never reads as free.
  var percent: String {
    guard fraction.isFinite else { return "–" }
    return "\(max(Int((fraction * 100).rounded()), 1))%"
  }

  var label: String {
    switch fraction {
    case ...0.5: "Plenty of room"
    case ...0.8: "Fits"
    case ...1: "Tight fit"
    default: "Over budget"
    }
  }

  var tint: Color {
    switch fraction {
    case ...0.8: .green
    case ...1: .orange
    default: .red
    }
  }
}

/// The weights and the context side by side on a track as wide as the budget.
/// Over budget, the track stretches to the total and a tick marks where the
/// budget ends.
private struct MemoryBar: View {
  let weightsMb: Double
  let contextMb: Double
  let fit: MemoryFit

  var body: some View {
    GeometryReader { geometry in
      let scale = geometry.size.width / max(fit.budgetMb, weightsMb + contextMb, 1)
      // A sliver stays visible however small the share, so both parts read.
      let weights = weightsMb > 0 ? max(weightsMb * scale, 3) : 0
      let context = contextMb > 0 ? max(contextMb * scale, 3) : 0
      ZStack(alignment: .leading) {
        Capsule().fill(Color(.tertiarySystemFill))
        HStack(spacing: 1) {
          Rectangle().fill(fit.tint).frame(width: weights)
          Rectangle().fill(fit.tint.opacity(0.45)).frame(width: context)
        }
        .clipShape(.capsule)
        if fit.fraction > 1 {
          Rectangle()
            .fill(Color.primary)
            .frame(width: 2)
            .offset(x: fit.budgetMb * scale - 1)
        }
      }
    }
    .frame(height: 8)
  }
}

/// Chips left to right, wrapping to a new line when the next one won't fit:
/// a model can show up to seven, more than a phone row holds.
private struct ChipFlow: Layout {
  var spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let frames = arrange(subviews, width: proposal.width ?? .infinity)
    let width = frames.map(\.maxX).max() ?? 0
    let height = frames.map(\.maxY).max() ?? 0
    return CGSize(width: width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for (subview, frame) in zip(subviews, arrange(subviews, width: bounds.width)) {
      subview.place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        proposal: ProposedViewSize(frame.size))
    }
  }

  /// Each subview's frame, rows top-aligned and as tall as their tallest chip.
  private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
    var frames: [CGRect] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
    return frames
  }
}

// MARK: - SDK 27 with a fallback

private extension View {
  /// Swipe actions on the cards, which aren't `List` rows. Before iOS 27 the context
  /// menu still offers Delete.
  @ViewBuilder func swipeActionsContainerIfAvailable() -> some View {
    if #available(iOS 27, *) {
      swipeActionsContainer()
    } else {
      self
    }
  }

  /// An alert shown while `item` holds a value, which its closures receive.
  @ViewBuilder func itemAlert<T, A: View, M: View>(
    _ title: String, item: Binding<T?>,
    @ViewBuilder actions: @escaping (T) -> A, @ViewBuilder message: @escaping (T) -> M
  ) -> some View {
    if #available(iOS 27, *) {
      alert(title, item: item, actions: actions, message: message)
    } else {
      alert(title, isPresented: item.isPresent(), presenting: item.wrappedValue, actions: actions, message: message)
    }
  }

  /// A confirmation dialog shown while `item` holds a value, which its closures receive.
  @ViewBuilder func itemConfirmationDialog<T, A: View, M: View>(
    _ title: String, item: Binding<T?>,
    @ViewBuilder actions: @escaping (T) -> A, @ViewBuilder message: @escaping (T) -> M
  ) -> some View {
    if #available(iOS 27, *) {
      confirmationDialog(title, item: item, titleVisibility: .visible, actions: actions, message: message)
    } else {
      confirmationDialog(
        title, isPresented: item.isPresent(), titleVisibility: .visible, presenting: item.wrappedValue,
        actions: actions, message: message)
    }
  }
}

private extension Binding {
  /// Whether an optional holds a value; setting false clears it.
  func isPresent<T>() -> Binding<Bool> where Value == T? {
    Binding<Bool>(get: { wrappedValue != nil }, set: { if !$0 { wrappedValue = nil } })
  }
}

/// Asks for a Hugging Face repo, as `org/repo` or a link to it, and an optional quant.
private struct AddRepoSheet: View {
  let submit: (String, String?) -> Void
  @State private var repo = ""
  @State private var quant = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("org/repo", text: $repo)
            .accessibilityIdentifier("repoField")
          TextField("Quantization (optional), e.g. Q4_K_M", text: $quant)
        } footer: {
          Text("Any GGUF repo works. Without a quantization, the app picks one that fits this device.")
        }
      }
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .navigationTitle("Add from Hugging Face")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Find") {
            submit(normalizedRepo, quant.isEmpty ? nil : quant.trimmingCharacters(in: .whitespaces))
            dismiss()
          }
          .disabled(normalizedRepo.split(separator: "/").count != 2)
          .accessibilityIdentifier("findRepo")
        }
      }
    }
  }

  /// `org/repo`, also from a pasted `https://huggingface.co/org/repo/...` link.
  private var normalizedRepo: String {
    var value = repo.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in ["https://", "http://", "huggingface.co/", "hf.co/"] where value.hasPrefix(prefix) {
      value.removeFirst(prefix.count)
    }
    return value.split(separator: "/").prefix(2).joined(separator: "/")
  }
}
