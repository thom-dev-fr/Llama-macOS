import SwiftUI
import UIKit

@main
struct LlamaMobileApp: App {
  @State private var engine = EngineController()
  @State private var chat = ChatController()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      LibraryView(engine: engine, chat: chat)
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
