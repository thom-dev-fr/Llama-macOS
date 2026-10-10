import SwiftUI
import WebKit

/// The WebUI, kept for the app's lifetime: closing the chat keeps the page, so it
/// reopens where it was and an answer still being written isn't cut off.
@MainActor @Observable
final class ChatController {
  let files = FileInputPresenter()
  let page: WebPage
  /// The WebUI's conversation panel covers the page, with its own close button where
  /// the chat's sits. Only on a phone-width page: wider, the panel is a sidebar.
  private(set) var navigationCovers = false
  /// The page last asked for, so reopening on it keeps the conversation in view.
  private var requested: URL?
  /// Whether a `WebView` shows the page, from its appearance until its close
  /// animation has ended. A page can't be in two web views at once: WebKit traps
  /// when a second one takes it while the first is still zooming away.
  private(set) var isShown = false

  init() {
    let messages = NavigationMessages()
    var configuration = WebPage.Configuration()
    // The persistent store keeps the WebUI's IndexedDB history across launches.
    configuration.websiteDataStore = .default()
    let scripts = configuration.userContentController
    scripts.addUserScript(WKUserScript(
      source: Self.styleScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    scripts.addUserScript(WKUserScript(
      source: Self.navigationScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    scripts.add(messages, name: NavigationMessages.name)
    page = WebPage(configuration: configuration, dialogPresenter: files)
    page.isInspectable = true
    messages.received = { [weak self] covers in self?.navigationCovers = covers }
  }

  /// The page to show next, loaded once the chat is on screen.
  private var pending: URL?

  /// Shows `url` when the chat appears, unless it is already the page asked for.
  func open(_ url: URL) {
    guard url != requested else { return }
    requested = url
    pending = url
  }

  func appeared() {
    isShown = true
    loadPending()
  }

  func disappeared() {
    isShown = false
  }

  /// Loads the page `open` asked for. Called once the web view is on screen.
  private func loadPending() {
    guard let url = pending else { return }
    pending = nil
    navigationCovers = false
    page.load(URLRequest(url: url))
  }

  /// The least that makes the WebUI pass for native: the system background behind
  /// the page and the system accent on its controls, both through the CSS variables
  /// the WebUI defines on `:root` and `.dark` (the doubled selectors outrank its own,
  /// whichever stylesheet loads last); no grey flash on tap; no text inflation on
  /// rotation; no scroll indicators, on the page (WebKit reads `scrollbar-width` on
  /// the root for the web view's own) or in the WebUI's scrolling panes; and no rubber band at the page's ends, which dragged the WebUI's
  /// pinned header and input along. Nothing here touches layout or type: the WebUI is
  /// sized in rem, so even a root font size reflows all of it.
  ///
  /// One exception: notifications drop in from the top, under the WebUI's header, as
  /// the system's banners do, instead of covering the input at the bottom. Its
  /// toaster (svelte-sonner) sets where toasts enter and stack from with `--lift`
  /// and `--y`, keyed on its bottom position, so those turn over with it; the entry
  /// offset applies only until a toast is mounted, when sonner's own rule takes over.
  private static let styleScript = """
    (() => {
      const style = document.createElement('style');
      style.textContent = `
        :root:root { --background: #FFFFFF; --primary: #0062CC; --primary-foreground: #FFFFFF; --ring: #0062CC; }
        :root.dark.dark { --background: #000000; --primary: #0A84FF; --primary-foreground: #FFFFFF; --ring: #0A84FF; }
        html {
          -webkit-tap-highlight-color: transparent;
          -webkit-text-size-adjust: 100%;
          overscroll-behavior: none;
        }
        * { scrollbar-width: none; }
        ::-webkit-scrollbar { display: none; }
        [data-sonner-toaster][data-y-position="bottom"][data-y-position] {
          bottom: auto; top: calc(env(safe-area-inset-top) + 4.5rem);
        }
        [data-sonner-toast][data-y-position="bottom"][data-y-position] {
          bottom: auto; top: 0; --lift: 1; --lift-amount: var(--gap);
        }
        [data-sonner-toast][data-y-position="bottom"]:not([data-mounted="true"]) { --y: translateY(-100%); }
      `;
      document.head.appendChild(style);
    })();
    """

  /// Reports whether the WebUI's conversation panel covers the page. Its Expand
  /// button exists only while the panel is closed; at the WebUI's `md` breakpoint
  /// and above the panel is a sidebar that covers nothing.
  private static let navigationScript = """
    (() => {
      let last;
      const report = () => {
        const covers = !document.querySelector('[aria-label="Expand navigation"]') && innerWidth < 768;
        if (covers === last) return;
        last = covers;
        webkit.messageHandlers.\(NavigationMessages.name).postMessage(covers);
      };
      new MutationObserver(report).observe(document.body, { childList: true, subtree: true });
      addEventListener('resize', report);
      report();
    })();
    """
}

/// Receives the navigation script's reports.
private final class NavigationMessages: NSObject, WKScriptMessageHandler {
  static let name = "navigation"
  var received: ((Bool) -> Void)?

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    received?(message.body as? Bool ?? false)
  }
}

/// The WebUI full screen. Its logo, top left, opens the conversations; the close
/// button sits across from it, and steps aside while the conversations cover the page.
struct ChatScreen: View {
  let chat: ChatController
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    WebView(chat.page)
      .fileInputs(chat.files)
      // The page scrolls under the status bar; the system background keeps it legible.
      .overlay(alignment: .top) {
        Color.clear
          .frame(height: 0)
          .background(Color(.systemBackground).ignoresSafeArea(edges: .top))
      }
      .overlay(alignment: .topTrailing) {
        if !chat.navigationCovers {
          Button("Close", systemImage: "xmark", role: .close) { dismiss() }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .controlSize(.large)
            .buttonBorderShape(.circle)
            // Centered on the WebUI's logo row, across from the logo.
            .padding(.top, 16)
            .padding(.trailing, 12)
            .transition(.opacity)
        }
      }
      .animation(.default, value: chat.navigationCovers)
      .onAppear { chat.appeared() }
      .onDisappear { chat.disappeared() }
  }
}
