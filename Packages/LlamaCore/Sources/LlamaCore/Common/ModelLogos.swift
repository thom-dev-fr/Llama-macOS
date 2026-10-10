import Foundation

/// Maps a model family or brand name to a logo asset in this package's
/// `ModelLogos.xcassets`, shared by the macOS and iOS apps. Without a curated catalog the brand is
/// inferred by keyword — the single table here serves both the installed rows
/// (matched on the name parsed from the id) and the Discover rows (matched on the
/// catalog's brand field), so the two can't drift apart.
public enum ModelLogos {
  /// Keyword → logo asset. Several Mistral lines share one mark; GLM is z.ai's;
  /// Nemotron is NVIDIA's; Laguna is Poolside's; Clef is Cloudflare's; LFM is Liquid AI's. Order
  /// only matters where keywords overlap (none do).
  private static let brands: [(keyword: String, asset: String)] = [
    ("qwen", "qwen"),
    ("gemma", "gemma"),
    ("openai", "gpt"),
    ("gpt", "gpt"),
    ("mistral", "mistral"),
    ("ministral", "mistral"),
    ("devstral", "mistral"),
    ("magistral", "mistral"),
    ("glm", "z"),
    ("nemotron", "nvidia"),
    ("nvidia", "nvidia"),
    ("laguna", "poolside"),
    ("deepseek", "deepseek"),
    ("clef", "cloudflare"),
    ("cloudflare", "cloudflare"),
    ("lfm", "liquid"),
    ("liquid", "liquid"),
  ]

  /// The bundle holding the logo catalog. Load an asset from here, not the app's
  /// main bundle: `NSImage` / `UIImage(named:in:with:)` or `Image(_:bundle:)`.
  public static let bundle = Bundle.module

  /// Returns the asset name (e.g. "ModelLogos/qwen") for a family/brand name,
  /// or nil when no keyword matches — callers fall back to a generic symbol.
  public static func asset(matching name: String) -> String? {
    let haystack = name.lowercased()
    guard let asset = brands.first(where: { haystack.contains($0.keyword) })?.asset
    else { return nil }
    return "ModelLogos/\(asset)"
  }
}
