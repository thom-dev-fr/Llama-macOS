import SwiftUI
import UIKit

@main
struct LlamaMobileApp: App {
  @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
  @State private var library = ModelLibrary()
  @State private var engine = EngineController()
  @State private var chat = ChatController()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      LibraryView(library: library, engine: engine, chat: chat)
        .onChange(of: library.presetRevision, initial: true) {
          if library.presetRevision > 0 { engine.setPresets(library.presetsURL) }
        }
        // iOS suspends background apps, so generation cannot continue there, and the
        // model would hold memory for nothing.
        .onChange(of: scenePhase, initial: true) { _, phase in
          switch phase {
          case .active: engine.activate()
          case .background: engine.deactivate()
          default: break
          }
        }
    }
  }
}

/// Connects the background download session to the app's lifecycle.
final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    // Reconnects to transfers started before a relaunch, so their files are
    // placed even when iOS launched the app in the background to deliver them.
    _ = DownloadSession.shared
    return true
  }

  func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    guard identifier == DownloadSession.identifier else { return completionHandler() }
    nonisolated(unsafe) let completionHandler = completionHandler
    DownloadSession.shared.setBackgroundCompletion { completionHandler() }
  }
}
