# Llama for iOS (prototype)

A standalone iPhone and iPad app: models run on the device, with no Mac involved, and work offline once downloaded. This prototype checks that the parts the Mac app relies on also work inside an iOS app, before building the full experience:

- llama.cpp embedded in the app process, with Metal
- the llama.cpp server running in-process, with no child process
- the llama.cpp WebUI in a SwiftUI `WebView`, including switching models from its picker

A native screen handles the engine; conversations happen in the WebUI.

## Build and run

Requirements: Xcode with the iOS 26 SDK or later, and CMake (`brew install cmake`). The app targets iOS 26 and builds in Swift 6 with main-actor default isolation, so types used off the main actor are marked `nonisolated`.

1. To run on a device, create `iOS/Signing.local.xcconfig` (git ignores it) with your team and a bundle ID prefix that team can register:

   ```
   DEVELOPMENT_TEAM = ABCDE12345
   BUNDLE_ID_PREFIX = com.example
   ```

   The simulator needs no signing.

2. Build and run the `Llama-iOS` scheme. The first build clones llama.cpp into `build/llama.cpp` and compiles it, which takes a few minutes. Later builds are incremental.

3. In the app, open the WebUI from the engine bar: the engine already runs. There are no models to choose from yet.

## TestFlight

With `DEVELOPMENT_TEAM` and `BUNDLE_ID_PREFIX` set as above, and an app for `<prefix>.ios` in App Store Connect, archive and upload:

```
xcodebuild -project Llama.xcodeproj -scheme Llama-iOS -configuration Release -destination 'generic/platform=iOS' -archivePath build/Llama-iOS.xcarchive -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath build/Llama-iOS.xcarchive -exportOptionsPlist iOS/ExportOptions.plist -exportPath build/export -allowProvisioningUpdates
```

`ExportOptions.plist` uploads to App Store Connect with automatic signing, and lets Xcode raise the build number above the last upload.

## Layout

| Path | Role |
| --- | --- |
| `App/LlamaMobileApp.swift` | Entry point. Runs the engine while the app is in the foreground. |
| `App/LibraryView.swift` | Native screen: the engine's state, the loaded model, and the WebUI sheet. |
| `App/EngineController.swift` | Runs the embedded server in the foreground, without a model until one is chosen, and mirrors its state. The only Swift code that calls the C API. |
| `Engine/MobileServer.{h,cpp}` | The embedded server and its C API. |
| `Engine/CMakeLists.txt` | Builds llama.cpp and the server as static libraries. |
| `Signing.xcconfig` | Signing settings shared by the iOS targets. |
| `../Packages/LlamaCore/` | Code shared with the macOS app: model ids, memory fit and context tiers for a given memory budget, Hugging Face resolution, cache scan and download plan, `llama://` links, the remote catalog. Linked but not used yet. Tests: `swift test` in that folder. |
| `../scripts/build-ios-engine.sh` | Pins llama.cpp and builds `libLlamaMobile.a` for the current SDK. Xcode runs it before compiling. |

## How the engine works

```
LibraryView ──► EngineController ──► MobileServer C API
                                          │
WebView (WebUI) ────HTTP 127.0.0.1:18080──► MobileServer router ──► one server_context
```

On macOS, `llama serve` runs in router mode: the router starts one `llama-server` process per model and forwards requests to it. The WebUI's model picker relies on that mode. iOS apps cannot start processes, and the llama.cpp router refuses to run without them.

`MobileServer.cpp` therefore serves the router API itself (`/props`, `/models`, `/models/load`, `/models/unload`, `/models/sse`), from a single process. It hands chat and `/v1/systemone` requests to the unmodified llama.cpp handlers of the model they name, loading that model first if needed. A `/v1/systemone` response carries a `Server-Timing` header (`load;dur=…, compute;dur=…`, in milliseconds), which upstream doesn't send. Only one model is in memory at a time: a switch waits for requests in progress, frees the current model, then loads the next one. The comment at the top of the file explains the design and its locking.

## Updating llama.cpp

The iOS engine builds the same llama.cpp release the macOS app downloads (`LlamaBinaries.targetVersion`).

1. Set `TAG` and `COMMIT` in `scripts/build-ios-engine.sh`. The build warns when `TAG` differs from the macOS version.
2. Compare the router JSON in `MobileServer.cpp` with `tools/server/server-models.cpp` at the new version, and check that `common/preset.h` and `common/fit.h` still offer what it calls.

## Known limitations

- Fixed port 18080, which keeps the WebUI origin and therefore its chat history stable. Another app on the device could use that port too.
- The engine stops when the app goes to the background, which frees the model and ends a generation in progress; it starts again, without a model, when the app comes back.
- WebUI tools, MCP and the CORS proxy are disabled.
- Decision models stay in the WebUI's picker, as on the Mac: the WebUI doesn't tell them apart yet, and chatting with one fails. `/models` reports their `decision` tag and `decisions` output modality.
