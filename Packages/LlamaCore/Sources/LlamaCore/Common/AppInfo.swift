import Foundation

public enum AppInfo {
  public static var shortVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
  }

  public static var buildNumber: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
  }

  /// Identifies the app in outbound HTTP requests.
  ///
  /// URLSession's default agent is derived from the bundle name — `Llama/0.42.0
  /// CFNetwork/… Darwin/…` — which is too generic to filter on (llama.cpp and
  /// several unrelated tools share the token). Hugging Face keys its request
  /// logs on User-Agent, so an explicit, stable string is what makes model
  /// downloads attributable to this app rather than lost in generic traffic.
  ///
  /// Unreleased builds report version `0.0.0` (the Xcode default), which keeps
  /// local development out of any download metric derived from this.
  public static var userAgent: String {
    let os = ProcessInfo.processInfo.operatingSystemVersion
    #if os(iOS)
      let platform = "iOS"
    #else
      let platform = "macOS"
    #endif
    // Literal: the app is Apple Silicon only (`ARCHS = arm64`, and the engine
    // installer only fetches `aarch64` builds).
    return "llama-app/\(shortVersion) (\(platform) \(os.majorVersion).\(os.minorVersion); arm64)"
  }

  /// Checks for `LB_DEBUG_UI` environment variable to enable visual layout debugging
  public static var isUIDebugEnabled: Bool {
    ProcessInfo.processInfo.environment["LB_DEBUG_UI"] != nil
  }
}
