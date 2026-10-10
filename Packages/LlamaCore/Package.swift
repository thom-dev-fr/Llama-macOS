// swift-tools-version: 6.0
import PackageDescription

// Platform-independent code shared by the macOS and iOS apps: model identity and
// compatibility, Hugging Face resolution and cache layout, and download bookkeeping.
// Nothing here may depend on AppKit, UIKit, a child process, or app settings.
// The one resource is the brand logo catalog, which both apps draw from.
let package = Package(
  name: "LlamaCore",
  platforms: [.macOS(.v15), .iOS("26.0")],
  products: [
    .library(name: "LlamaCore", targets: ["LlamaCore"])
  ],
  targets: [
    .target(name: "LlamaCore", resources: [.process("Resources")]),
    .testTarget(name: "LlamaCoreTests", dependencies: ["LlamaCore"]),
  ]
)
