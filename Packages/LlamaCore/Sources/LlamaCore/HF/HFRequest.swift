import Foundation

/// Builds requests to Hugging Face -- the single place that decides which
/// headers go out, so the API lookup, the metadata HEADs and the downloads
/// can't drift apart.
public enum HFRequest {
  /// A request carrying the app's User-Agent, plus the user's token when `url`
  /// is on Hugging Face.
  public static func make(_ url: URL, token: String?) -> URLRequest {
    var request = URLRequest(url: url)
    request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
    // Match the host exactly or as a subdomain -- a bare `hasSuffix` would also
    // accept `evilhuggingface.co`, and this check is the only thing keeping the
    // token off a third-party host.
    let host = url.host ?? ""
    if let token, host == "huggingface.co" || host.hasSuffix(".huggingface.co") {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    return request
  }

  /// Whether a string looks like a Hugging Face access token.
  public static func isValidToken(_ token: String) -> Bool {
    token.hasPrefix("hf_")
      && token.count > 3
      && token.dropFirst(3).allSatisfy { $0.isLetter || $0.isNumber }
  }

  /// Maps HTTP status codes to user-facing guidance. We deliberately don't claim a
  /// specific cause (rate limit vs. gated repo vs. CDN outage) — Hugging Face uses
  /// these codes for several reasons, so we hedge with "usually" and point the user
  /// at the most common remedy.
  public static func failureMessage(forHTTPStatus status: Int) -> String {
    switch status {
    case 401:
      return
        "Hugging Face requires authentication for this download. Set a Hugging Face token in Settings and try again."
    case 403, 429:
      return
        "Hugging Face refused the download (HTTP \(status)). This usually means a rate limit — try again in a few minutes, or set a Hugging Face token in Settings to lift the limit."
    case 404:
      return
        "Hugging Face returned 404 for this file. The repo may have moved or been removed."
    case 500...599:
      return
        "Hugging Face is temporarily unavailable (HTTP \(status)). Try again in a few minutes."
    default:
      return "Download failed with HTTP \(status)."
    }
  }
}
