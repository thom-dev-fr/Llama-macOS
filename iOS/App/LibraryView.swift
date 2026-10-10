import LlamaCore
import SwiftUI

/// Native screen for the engine. Conversations happen in the WebUI, which opens full
/// screen from the engine bar.
struct LibraryView: View {
  let engine: EngineController
  let chat: ChatController
  /// The WebUI on screen, zoomed from the button that opened it.
  @State private var chatting: ChatSource?
  /// A chat asked for while the last one is still closing, shown once it has.
  @State private var queuedChat: ChatSource?
  @Namespace private var transition

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          errors
        }
        .padding(.horizontal)
        .padding(.bottom)
      }
      .background(Color(.systemGroupedBackground))
      .navigationTitle("Models")
      // Always in reach: what the engine holds, and the way back to the chat.
      .safeAreaInset(edge: .bottom) { engineBar }
      .fullScreenCover(item: $chatting) { source in
        ChatScreen(chat: chat)
          .navigationTransition(.zoom(sourceID: source.id, in: transition))
      }
      .onChange(of: chat.isShown) { _, shown in
        guard !shown, let queued = queuedChat else { return }
        queuedChat = nil
        chatting = queued
      }
    }
  }

  // MARK: - Sections

  /// At the top, where they are seen: a failure to start.
  @ViewBuilder private var errors: some View {
    ForEach([engine.error].compactMap { $0 }, id: \.self) { error in
      Label(error, systemImage: "exclamationmark.triangle.fill")
        .font(.subheadline)
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityIdentifier("error")
    }
  }

  // MARK: - Engine

  /// The loaded model, with Unload and a way back to the chat; or the engine
  /// starting, or a Start after a failed start.
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
          Text(ModelIdParser.plainName(id, showTags: false)).fontWeight(.semibold)
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

  // MARK: - Chat

  private func openChat(_ url: URL, from source: String) {
    chat.open(url)
    if chat.isShown {
      queuedChat = ChatSource(id: source)
    } else {
      chatting = ChatSource(id: source)
    }
  }
}

/// What the chat zooms from: the engine bar's button.
private struct ChatSource: Identifiable {
  let id: String
}

private extension View {
  /// A rounded card on the grouped background, as the list's rows.
  func card() -> some View {
    padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
  }
}
