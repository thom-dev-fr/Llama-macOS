# Llama for iOS (prototype)

A standalone iPhone and iPad app: models run on the device, with no Mac involved, and work offline once downloaded. This prototype checks that the parts the Mac app relies on also work inside an iOS app, before building the full experience:

- llama.cpp embedded in the app process, with Metal
- the llama.cpp server running in-process, with no child process
- the llama.cpp WebUI in a SwiftUI `WebView`, including switching models from its picker

A native screen handles models and the engine; conversations happen in the WebUI.

## Build and run

Requirements: Xcode with the iOS 26 SDK or later, and CMake (`brew install cmake`). The app targets iOS 26 and builds in Swift 6 with main-actor default isolation, so types used off the main actor are marked `nonisolated`.

1. To run on a device, create `iOS/Signing.local.xcconfig` (git ignores it) with your team and a bundle ID prefix that team can register:

   ```
   DEVELOPMENT_TEAM = ABCDE12345
   BUNDLE_ID_PREFIX = com.example
   ```

   The simulator needs no signing.

2. Build and run the `Llama-iOS` scheme. The first build clones llama.cpp into `build/llama.cpp` and compiles it, which takes a few minutes. Later builds are incremental.

3. In the app, get a recommended model or add one from Hugging Face, then tap Chat on it: the engine already runs, and the WebUI opens on that model. `llama://install?repo=org/repo[&quant=Q4_K_M]` links, like the ones on llama.app, open the app on the same confirmation. On the simulator: `xcrun simctl openurl booted "llama://install?repo=unsloth/SmolLM2-135M-Instruct-GGUF&quant=Q8_0"`.

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
| `App/LlamaMobileApp.swift` | Entry point. Connects the model library to the engine, runs the engine while the app is in the foreground, and hands background download events to the session. |
| `App/LibraryView.swift` | Native screen: installed models, recommendations and a link to the full llama.app catalog, adding a Hugging Face repo, install links, downloads, a Chat button per model, the loaded model, and the WebUI sheet. |
| `App/ModelLibrary.swift` | Models in the app's Hugging Face cache (`Application Support/huggingface/hub`, excluded from backups), and installing through the shared resolver. |
| `App/DownloadSession.swift` | The background download session: each file is checked against Hugging Face's SHA-256 and placed in the cache layout, even when iOS relaunches the app in the background to deliver it. Stopped transfers keep their resume data. A model that finishes or fails is announced with a notification. |
| `App/SettingsView.swift` | Settings: Hugging Face token, cellular data, storage, versions, and the engine log and `models.ini` for diagnosis. |
| `App/Keychain.swift` | The Hugging Face token, kept in this device's Keychain only. |
| `App/DeviceMemory.swift` | The memory budget models are checked against: the process limit iOS enforces, less a margin. |
| `App/EngineController.swift` | Runs the embedded server in the foreground, without a model until one is chosen, and mirrors its state. The only Swift code that calls the C API. |
| `Engine/MobileServer.{h,cpp}` | The embedded server and its C API. |
| `Engine/CMakeLists.txt` | Builds llama.cpp and the server as static libraries. |
| `UITests/` | End-to-end tests: chat through the WebUI and model switching through the server API. |
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

The models come from `models.ini`, generated like the Mac's by `ModelPreset` in LlamaCore: one section per installed model with its path, context size, image projector, draft head and tags. The engine reads it with llama.cpp's own preset parser and applies each section to its model's parameters, as `llama serve --models-preset` does for each child server. Memory is measured in-process with the figures `llama fit-params -fitp on` prints on the Mac, at 4K and 128K, and fitted into the same `MemProfile`; that is what limits the context sizes offered.

## Updating llama.cpp

The iOS engine builds the same llama.cpp release the macOS app downloads (`LlamaBinaries.targetVersion`).

1. Set `TAG` and `COMMIT` in `scripts/build-ios-engine.sh`. The build warns when `TAG` differs from the macOS version.
2. Compare the router JSON in `MobileServer.cpp` with `tools/server/server-models.cpp` at the new version, and check that `common/preset.h` and `common/fit.h` still offer what it calls.
3. Run the UI tests.

## Tests

Run the `Llama-iOS` scheme's tests on a simulator or a device. They install two SmolLM2 models through `llama://install` links on first run, about 530 MB, a small vision model with its projector (280 MB), and download a third text model (270 MB) on every run to check stopping, resuming and finishing in the background.

Simulators share the Mac's network, so the server port is shared too. Quit the app in any other simulator before running the tests.

## Known limitations

- Fixed port 18080, which keeps the WebUI origin and therefore its chat history stable. Another app on the device could use that port too.
- Settings other than the context size can't be changed on the device: no equivalent of the Mac's `models.user.ini` yet.
- The engine stops when the app goes to the background, which frees the model and ends a generation in progress; it starts again, without a model, when the app comes back.
- Downloads use Wi-Fi only unless cellular data is allowed; that choice applies to downloads started afterwards.
- A model above the memory estimate gets a warning, not a refusal, and runs at 4K.
- Images and audio reach models whose projector supports them, through the WebUI's attachments. Recording from the microphone inside the WebUI is untested.
- WebUI tools, MCP and the CORS proxy are disabled.
- Decision models stay in the WebUI's picker, as on the Mac: the WebUI doesn't tell them apart yet, and chatting with one fails. `/models` reports their `decision` tag and `decisions` output modality.
