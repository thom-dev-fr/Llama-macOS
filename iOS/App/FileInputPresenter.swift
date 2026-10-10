import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Answers the WebUI's file inputs. A `WebPage` cancels them unless its dialog presenter
/// picks the files, so without this the attach button does nothing. Offers the photo
/// library, the camera or the Files app, as Safari does.
@MainActor @Observable
final class FileInputPresenter: WebPage.DialogPresenting {
  /// The choice between the photo library, the camera and the Files app is showing.
  var isChoosing = false
  var showsPhotos = false
  var showsCamera = false
  var showsFiles = false
  /// The simulator and some iPads have no camera.
  let hasCamera = UIImagePickerController.isSourceTypeAvailable(.camera)
  private(set) var allowsMultiple = true
  private var pending: CheckedContinuation<WebPage.FileInputPromptResult, Never>?

  func handleFileInputPrompt(
    parameters: WKOpenPanelParameters, initiatedBy frame: WebPage.FrameInfo
  ) async -> WebPage.FileInputPromptResult {
    finish(.cancel) // a prompt still open
    allowsMultiple = parameters.allowsMultipleSelection
    isChoosing = true
    return await withCheckedContinuation { pending = $0 }
  }

  /// Answers the open prompt; later calls do nothing.
  func finish(_ result: WebPage.FileInputPromptResult) {
    pending?.resume(returning: result)
    pending = nil
  }

  /// Cancels the prompt when the choice is dismissed without picking a source.
  func choiceDismissed() {
    // A source button's action may run after the dismissal.
    DispatchQueue.main.async { [self] in
      if !showsPhotos && !showsCamera && !showsFiles { finish(.cancel) }
    }
  }

  func filesPicked(_ result: Result<[URL], Error>) {
    guard case .success(let urls) = result, !urls.isEmpty, let continuation = pending
    else { return finish(.cancel) }
    pending = nil // picker dismissal must not cancel the copy in progress
    Task {
      let copies = await AttachmentFiles.copy(urls)
      continuation.resume(returning: copies.isEmpty ? .cancel : .selected(copies))
    }
  }

  func photosPicked(_ results: [PHPickerResult]) {
    guard !results.isEmpty, let continuation = pending else { return finish(.cancel) }
    pending = nil // answered once the photos are saved
    Task {
      var urls: [URL] = []
      for (index, result) in results.enumerated() {
        if let url = await Self.image(from: result.itemProvider, index: index) { urls.append(url) }
      }
      continuation.resume(returning: urls.isEmpty ? .cancel : .selected(urls))
    }
  }

  func photoTaken(_ image: UIImage?) {
    guard let image, let continuation = pending else { return finish(.cancel) }
    pending = nil
    Task {
      let url = await AttachmentFiles.saveCameraImage(image)
      continuation.resume(returning: url.map { .selected([$0]) } ?? .cancel)
    }
  }

  /// Saves a picked photo as PNG or JPEG, the formats the WebUI and the model read;
  /// HEIC and others become JPEG.
  private static func image(from provider: NSItemProvider, index: Int) async -> URL? {
    let kept: [UTType] = [.png, .jpeg]
    let type = kept.first { provider.hasItemConformingToTypeIdentifier($0.identifier) } ?? .image
    guard let data = await load(provider, type: type) else { return nil }
    return await AttachmentFiles.savePhoto(data, type: type, name: "photo-\(index + 1)")
  }

  private static func load(_ provider: NSItemProvider, type: UTType) async -> Data? {
    await withCheckedContinuation { continuation in
      _ = provider.loadDataRepresentation(for: type) { data, _ in continuation.resume(returning: data) }
    }
  }
}

/// File access and photo encoding shared by the attachment flows. Only the finished
/// URLs/data cross back to the UI; security-scoped access covers the entire disk read.
nonisolated enum AttachmentFiles {
  @concurrent
  static func copy(_ urls: [URL]) async -> [URL] {
    urls.compactMap { source in
      let accessing = source.startAccessingSecurityScopedResource()
      defer { if accessing { source.stopAccessingSecurityScopedResource() } }
      do {
        let destination = try destination(name: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
      } catch { return nil }
    }
  }

  @concurrent
  static func read(_ url: URL) async -> Data? {
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    return try? Data(contentsOf: url)
  }

  @concurrent
  static func saveCameraImage(_ image: UIImage) async -> URL? {
    autoreleasepool {
      image.jpegData(compressionQuality: 0.9).flatMap { save($0, name: "photo.jpg") }
    }
  }

  @concurrent
  static func savePhoto(_ data: Data, type: UTType, name: String) async -> URL? {
    autoreleasepool {
      if type == .png || type == .jpeg {
        return save(data, name: "\(name).\(type.preferredFilenameExtension ?? "img")")
      }
      guard let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.9) else { return nil }
      return save(jpeg, name: "\(name).jpg")
    }
  }

  private static func save(_ data: Data, name: String) -> URL? {
    do {
      let url = try destination(name: name)
      try data.write(to: url)
      return url
    } catch { return nil }
  }

  /// Writes to a fresh temporary folder, so names never collide.
  private static func destination(name: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("Attachments", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent(name)
  }
}

extension View {
  /// Shows the pickers `presenter` asks for.
  func fileInputs(_ presenter: FileInputPresenter) -> some View {
    @Bindable var presenter = presenter
    return self
      .confirmationDialog("Attach", isPresented: $presenter.isChoosing, titleVisibility: .hidden) {
        Button("Photo Library") { presenter.showsPhotos = true }
        if presenter.hasCamera {
          Button("Take Photo") { presenter.showsCamera = true }
        }
        Button("Choose File") { presenter.showsFiles = true }
        Button("Cancel", role: .cancel) { presenter.finish(.cancel) }
      }
      .onChange(of: presenter.isChoosing) { _, choosing in
        if !choosing { presenter.choiceDismissed() }
      }
      .sheet(isPresented: $presenter.showsPhotos, onDismiss: { presenter.finish(.cancel) }) {
        PhotoPicker(limit: presenter.allowsMultiple ? 0 : 1) { presenter.photosPicked($0) }
          .ignoresSafeArea()
      }
      .fullScreenCover(isPresented: $presenter.showsCamera, onDismiss: { presenter.finish(.cancel) }) {
        Camera { presenter.photoTaken($0) }
          .ignoresSafeArea()
      }
      .fileImporter(
        isPresented: $presenter.showsFiles, allowedContentTypes: [.item],
        allowsMultipleSelection: presenter.allowsMultiple,
        onCompletion: { presenter.filesPicked($0.map { $0 }) },
        onCancellation: { presenter.finish(.cancel) })
  }
}

/// The system photo picker. Reports once, with no results when cancelled, which
/// SwiftUI's `PhotosPicker` doesn't tell apart from a dismissal. A swipe down reports
/// nothing; the sheet's `onDismiss` cancels then.
private struct PhotoPicker: UIViewControllerRepresentable {
  let limit: Int
  let picked: ([PHPickerResult]) -> Void

  func makeUIViewController(context: Context) -> PHPickerViewController {
    var configuration = PHPickerConfiguration()
    configuration.filter = .images
    configuration.selectionLimit = limit
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(picked: picked) }

  final class Coordinator: NSObject, PHPickerViewControllerDelegate {
    var picked: (([PHPickerResult]) -> Void)?
    init(picked: @escaping ([PHPickerResult]) -> Void) { self.picked = picked }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
      picker.dismiss(animated: true)
      picked?(results)
      picked = nil
    }
  }
}

/// The system camera. Reports once, with nil when cancelled.
struct Camera: UIViewControllerRepresentable {
  let taken: (UIImage?) -> Void

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let camera = UIImagePickerController()
    camera.sourceType = .camera
    camera.delegate = context.coordinator
    return camera
  }

  func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(taken: taken) }

  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    var taken: ((UIImage?) -> Void)?
    init(taken: @escaping (UIImage?) -> Void) { self.taken = taken }

    func imagePickerController(
      _ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      report(info[.originalImage] as? UIImage, from: picker)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      report(nil, from: picker)
    }

    private func report(_ image: UIImage?, from picker: UIImagePickerController) {
      picker.dismiss(animated: true)
      taken?(image)
      taken = nil
    }
  }
}
