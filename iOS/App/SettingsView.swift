import LlamaCore
import SwiftUI

/// Settings: the Hugging Face token, the network downloads may use, the storage
/// the models take, and what the engine was given and wrote, to diagnose a problem.
struct SettingsView: View {
  @Bindable var library: ModelLibrary
  @State private var tokenText = ""
  @State private var tokenError: String?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        tokenSection
        Section {
          Toggle("Allow cellular data", isOn: $library.allowCellular)
            .accessibilityIdentifier("allowCellular")
        } header: {
          Text("Downloads")
        } footer: {
          Text("Downloads use Wi-Fi unless cellular data is allowed; the choice applies to downloads started afterwards. They continue in the background, and a stopped one continues where it stopped.")
        }
        storageSection
        diagnosticsSection
        aboutSection
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
    }
  }

  private var trimmedToken: String {
    tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var tokenSection: some View {
    Section {
      if library.hasToken {
        Label("Token saved", systemImage: "key.fill")
          .accessibilityIdentifier("tokenSaved")
        Button("Remove the token", role: .destructive) { library.removeToken() }
      }
      SecureField(library.hasToken ? "Replace with a new token" : "hf_…", text: $tokenText)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .accessibilityIdentifier("tokenField")
      if !trimmedToken.isEmpty && !HFRequest.isValidToken(trimmedToken) {
        Text("This doesn't look like a Hugging Face token.").font(.caption).foregroundStyle(.red)
      }
      if let tokenError {
        Text(tokenError).font(.caption).foregroundStyle(.red)
      }
      Button("Save the token") {
        do {
          try library.saveToken(trimmedToken)
          tokenText = ""
          tokenError = nil
        } catch {
          tokenError = error.localizedDescription
        }
      }
      .disabled(!HFRequest.isValidToken(trimmedToken))
      .accessibilityIdentifier("saveToken")
    } header: {
      Text("Hugging Face")
    } footer: {
      VStack(alignment: .leading, spacing: 4) {
        Text("Only needed for gated or private models. Kept in this device's Keychain, never synced.")
        Link("Create a token", destination: URL(string: "https://huggingface.co/settings/tokens")!)
      }
    }
  }

  private var storageSection: some View {
    Section {
      LabeledContent(
        "Models", value: "\(ModelLibrary.size(library.installedBytes)) · \(library.installed.count)")
      LabeledContent("Available", value: ModelLibrary.size(library.availableBytes))
    } header: {
      Text("Storage")
    } footer: {
      Text("Models stay out of device backups and can be downloaded again. Conversations are stored separately, on this device only: deleting a model keeps them.")
    }
  }

  private var diagnosticsSection: some View {
    Section {
      NavigationLink("Engine log") {
        TextFileView(title: "Engine log", url: EngineController.logURL, showsEnd: true)
      }
      .accessibilityIdentifier("engineLog")
      NavigationLink("Model settings") {
        TextFileView(title: "Model settings", url: library.presetsURL, showsEnd: false)
      }
    } header: {
      Text("Diagnostics")
    } footer: {
      Text("The engine log covers the current or last run; it records model loading and errors, not what conversations say. Model settings are the models.ini the engine reads, like the Mac's.")
    }
  }

  private var aboutSection: some View {
    Section("About") {
      LabeledContent("Version", value: "\(AppInfo.shortVersion) (\(AppInfo.buildNumber))")
      LabeledContent("Engine", value: "llama.cpp \(String(cString: mobile_server_build_info()))")
      Link("Source code", destination: URL(string: "https://github.com/ggml-org/Llama-macOS")!)
    }
  }
}

/// A text file the app writes, read-only, with a share button to send it along
/// with a report.
private struct TextFileView: View {
  let title: String
  let url: URL
  /// Scrolls to the end, where a log's latest lines are.
  let showsEnd: Bool
  @State private var text: String?
  /// The most a view shows, from the end: a long log would make the text view crawl.
  private static let shownBytes = 256 * 1024

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        Text(text ?? "")
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding()
        Color.clear.frame(height: 1).id("end")
      }
      .overlay {
        if text?.isEmpty == true {
          ContentUnavailableView("Nothing yet", systemImage: "doc.text",
            description: Text("The file appears once the engine has run."))
        }
      }
      .task {
        text = await Task.detached { [url] in Self.read(url) }.value
        if showsEnd { proxy.scrollTo("end", anchor: .bottom) }
      }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if FileManager.default.fileExists(atPath: url.path) {
        ShareLink(item: url)
      }
    }
  }

  nonisolated private static func read(_ url: URL) -> String {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    let start = size > UInt64(shownBytes) ? size - UInt64(shownBytes) : 0
    try? handle.seek(toOffset: start)
    let data = (try? handle.readToEnd()) ?? Data()
    var text = String(decoding: data, as: UTF8.self)
    // Starts on a whole line when the beginning was cut.
    if start > 0, let newline = text.firstIndex(of: "\n") {
      text = "…" + text[newline...]
    }
    return text
  }
}
