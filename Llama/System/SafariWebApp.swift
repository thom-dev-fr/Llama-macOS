import AppKit
import Foundation
import LlamaCore
import os.log

/// A Safari Web App ("Add to Dock", Safari 17+) installed for the WebUI.
///
/// macOS doesn't route links to a web app on its own -- opening its URL
/// lands in the default browser even with one installed -- so WebUI links
/// find the app here and hand it the link directly.
///
/// A web app is an app bundle in `~/Applications` whose Info.plist embeds the
/// manifest Safari captured at install time, including the `start_url` it was
/// pinned to. Detection only, never installation: only Safari can create a
/// web app, and installing it is the user's Add to Dock.
@MainActor
enum SafariWebApp {

  private nonisolated static let logger = Logger(subsystem: Logging.subsystem, category: "SafariWebApp")

  /// The prefix Safari stamps on every web app's bundle identifier; the UUID
  /// that follows is per-install.
  private static let bundleIDPrefix = "com.apple.Safari.WebApp."

  private struct App {
    let url: URL
    let bundleID: String
    /// The host the app was pinned to, `localhost` or the LAN address --
    /// whichever the user installed it from.
    let host: String
  }

  /// Shows `url` (a WebUI link) in the web app installed for the server.
  /// Returns false when there is none, so the caller opens the browser.
  ///
  /// A bare origin ("Open chat") launches or activates the app, leaving a
  /// running one on whatever it shows. A link with a query (a model to
  /// select, a captured prompt) is delivered as an open-URL event, which the
  /// app turns into navigation -- the only way a web app takes a URL other
  /// than its start URL -- so the WebUI reads the same query a browser visit
  /// would. Either step failing falls back to the browser, so a click always
  /// opens something.
  static func open(_ url: URL) -> Bool {
    guard let app = installedApp(for: url),
      var link = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return false }

    // A web app only navigates within its own origin and hands anything else
    // to the default browser, so the link has to arrive on the host the app
    // was pinned to.
    link.host = app.host
    guard let linkURL = link.url else { return false }
    let deliver = link.query != nil

    enqueue(app.bundleID) {
      guard await launch(app) else {
        openInBrowser(url)
        return
      }
      guard deliver else { return }
      do {
        _ = try await NSWorkspace.shared.open(
          [linkURL], withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration())
      } catch {
        logger.error("Delivering link to web app: \(error.localizedDescription, privacy: .public)")
        // The original link, not the rehosted one: it's the server's own
        // address, while the rehosted one only made sense for the app.
        openInBrowser(url)
      }
    }
    return true
  }

  /// The fallback when the app can't take the link. Not awaited -- a cold
  /// browser start would hold up the next request for this app.
  private static func openInBrowser(_ url: URL) {
    NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
  }

  /// The web app pinned to the server `url` points at, if any.
  ///
  /// The menu builds its links from the resolved host (the LAN address while
  /// the server is exposed), while an app stays pinned to whatever host it was
  /// installed from. So an app matches on the link's own host, or on loopback
  /// while the server answers there -- one pinned to an address the server no
  /// longer serves is skipped, as its window would only show connection
  /// errors.
  private static func installedApp(for url: URL) -> App? {
    guard let host = url.host?.lowercased() else { return nil }
    var hosts: Set<String> = [host]
    if LlamaServer.servesLoopback {
      hosts.formUnion(["localhost", "127.0.0.1"])
    }

    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    // Sorted so that with several matching installs the pick is stable.
    for appURL in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    where appURL.pathExtension == "app" {
      // `Manifest`/`start_url` are Safari's own keys -- undocumented, so a
      // format change in a future Safari degrades to no match and the browser.
      guard let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")),
        let bundleID = info["CFBundleIdentifier"] as? String,
        bundleID.hasPrefix(bundleIDPrefix),
        let manifest = info["Manifest"] as? [String: Any],
        let startURLString = manifest["start_url"] as? String,
        let start = URLComponents(string: startURLString),
        start.scheme == url.scheme, start.port == url.port,
        let startHost = start.host?.lowercased(), hosts.contains(startHost)
      else { continue }
      return App(url: appURL, bundleID: bundleID, host: startHost)
    }
    return nil
  }

  /// Launches or activates the app. Returns false when LaunchServices refuses
  /// -- a matching plist doesn't guarantee a launchable bundle (one copied
  /// from another Mac reads as damaged, and registration can be rejected).
  ///
  /// A cold start also waits for the first page to be under way: a link
  /// delivered before there is a webview to navigate is swallowed, and the
  /// app stays on its start URL.
  private static func launch(_ app: App) async -> Bool {
    let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
    do {
      // Awaited rather than the synchronous open, which blocks the main
      // thread for as long as a cold launch takes.
      _ = try await NSWorkspace.shared.openApplication(
        at: app.url, configuration: NSWorkspace.OpenConfiguration())
    } catch {
      logger.error("Launching web app: \(error.localizedDescription, privacy: .public)")
      return false
    }
    if !wasRunning {
      try? await Task.sleep(nanoseconds: 2_000_000_000)
    }
    return true
  }

  /// The latest request per app, each awaiting the one before it. Without
  /// this, two clicks during a cold start (model A, then B) could land out of
  /// order: the second sees the app running, skips the wait, and delivers
  /// first -- and A's late delivery then navigates away from B.
  private static var chains: [String: Task<Void, Never>] = [:]

  /// Runs `body` once every earlier request for the same app has finished.
  private static func enqueue(_ bundleID: String, _ body: @escaping @MainActor () async -> Void) {
    let previous = chains[bundleID]
    chains[bundleID] = Task {
      await previous?.value
      await body()
    }
  }
}
