import XCTest

/// End-to-end checks on a simulator or device. They install two small models through
/// `llama://install` links on first run.
final class LlamaMobileUITests: XCTestCase {
  private let server = URL(string: "http://127.0.0.1:18080")!
  private let small = (repo: "unsloth/SmolLM2-135M-Instruct-GGUF", quant: "Q8_0")
  private let larger = (repo: "unsloth/SmolLM2-360M-Instruct-GGUF", quant: "Q8_0")

  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testLinkInstallAndWebUIInference() async throws {
    let app = XCUIApplication()
    app.launch()
    try await install(small, in: app)
    // The engine runs as soon as the app is open; Chat opens the WebUI on the model.
    let chat = app.buttons["chat-\(small.repo):\(small.quant)"]
    reveal(chat, in: app)
    let enabled = NSPredicate(format: "isEnabled == true")
    await fulfillment(of: [expectation(for: enabled, evaluatedWith: chat)], timeout: 120)
    chat.tap()
    let web = app.webViews.firstMatch
    XCTAssertTrue(web.waitForExistence(timeout: 30))
    ask("What is 2 + 2? Reply with just the number.", expecting: "4", in: web, of: app)
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "WebUI-local-inference"
    attachment.lifetime = .keepAlways
    add(attachment)

    // The background stops the engine and coming back starts it again: the open
    // WebUI keeps working, which catches stale server state and a listener that was
    // not released.
    XCUIDevice.shared.press(.home)
    XCTAssertTrue(app.wait(for: .runningBackgroundSuspended, timeout: 30) || app.state == .runningBackground)
    app.activate()
    ask("What is 3 + 3? Reply with just the number.", expecting: "6", in: web, of: app)

    app.buttons["Close"].tap()
    let open = app.buttons["openWebUI"]
    XCTAssertTrue(open.waitForExistence(timeout: 30))
    open.tap()
    // The WebUI reopens on a new chat; earlier ones are listed in its navigation.
    let navigation = web.buttons["Expand navigation"]
    XCTAssertTrue(navigation.waitForExistence(timeout: 30), app.debugDescription)
    navigation.tap()
    let previous = web.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "Reply with just the number")).firstMatch
    XCTAssertTrue(previous.waitForExistence(timeout: 10), "History must survive a server restart\n\(web.debugDescription)")
    // The open panel has its own close button where the chat's sits; the chat's steps aside.
    XCTAssertFalse(app.buttons["Close"].exists, app.debugDescription)
  }

  /// Sends a prompt in the WebUI and waits for an answer containing `expected`.
  @MainActor
  private func ask(_ prompt: String, expecting expected: String, in web: XCUIElement, of app: XCUIApplication) {
    let input = web.textViews.firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 60), app.debugDescription)
    input.tap()
    input.typeText(prompt)
    let send = web.buttons["Send"]
    XCTAssertTrue(send.waitForExistence(timeout: 10), app.debugDescription)
    send.tap()
    let answer = web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", expected)).firstMatch
    XCTAssertTrue(answer.waitForExistence(timeout: 120), app.debugDescription)
  }

  /// Drives the router API the WebUI model picker uses, from the test runner.
  @MainActor
  func testRouterSwitchesModels() async throws {
    let app = XCUIApplication()
    app.launch()
    try await install(small, in: app)
    try await install(larger, in: app)

    let loaded = "\(small.repo):\(small.quant)"
    let other = "\(larger.repo):\(larger.quant)"
    _ = try await post("/models/load", ["model": loaded])
    var statuses = try await modelStatuses()
    XCTAssertEqual(statuses[loaded], "loaded", "\(statuses)")
    XCTAssertEqual(statuses[other], "unloaded", "\(statuses)")

    // A request naming the other model swaps it in and frees the first.
    let (_, response) = try await post("/v1/chat/completions", [
      "model": other,
      "messages": [["role": "user", "content": "Say hi."]],
      "max_tokens": 8,
    ])
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    statuses = try await modelStatuses()
    XCTAssertEqual(statuses[other], "loaded")
    XCTAssertEqual(statuses[loaded], "unloaded")
    let loadedLabel = app.descendants(matching: .any).matching(identifier: "loadedModel")
      .matching(NSPredicate(format: "value == %@", other)).firstMatch
    XCTAssertTrue(loadedLabel.waitForExistence(timeout: 5), "The native screen follows the swap")

    _ = try await post("/models/unload", ["model": other])
    statuses = try await modelStatuses()
    XCTAssertEqual(Set(statuses.values), ["unloaded"])

    // The background frees a loaded model.
    _ = try await post("/models/load", ["model": loaded])
    XCUIDevice.shared.press(.home)
    XCTAssertTrue(app.wait(for: .runningBackgroundSuspended, timeout: 30) || app.state == .runningBackground)
    app.activate()
    await waitForEngine()
    statuses = try await modelStatuses()
    XCTAssertEqual(Set(statuses.values), ["unloaded"], "\(statuses)")
  }

  /// The context chosen on the native screen is what the engine loads the model with.
  @MainActor
  func testChosenContextReachesTheEngine() async throws {
    let app = XCUIApplication()
    app.launch()
    try await install(small, in: app)
    let id = "\(small.repo):\(small.quant)"
    reveal(app.buttons["chat-\(id)"], in: app)
    // The picker appears once the model's memory is measured.
    let context = app.buttons["context-\(id)"]
    XCTAssertTrue(context.waitForExistence(timeout: 120), app.debugDescription)
    context.tap()
    app.buttons["8K"].tap()
    // The screen shows the new size right away, not only after a relaunch.
    let shows8K = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "8K", "8K")
    await fulfillment(of: [expectation(for: shows8K, evaluatedWith: context)], timeout: 5)

    _ = try await post("/models/load", ["model": id])
    let entry = try await models()[id]
    XCTAssertEqual((entry?["meta"] as? [String: Any])?["n_ctx"] as? Int, 8192, "\(String(describing: entry))")
    XCTAssertEqual(entry?["tags"] as? [String], ["chat"])

    context.tap()
    app.buttons["4K"].tap()
  }

  /// A model with an image projector is listed as taking images, and answers one.
  @MainActor
  func testVisionModelAcceptsImages() async throws {
    let app = XCUIApplication()
    app.launch()
    let vision = (repo: "ggml-org/SmolVLM-256M-Instruct-GGUF", quant: "Q8_0")
    try await install(vision, in: app)
    let id = "\(vision.repo):\(vision.quant)"

    let architecture = try await models()[id]?["architecture"] as? [String: Any]
    XCTAssertEqual(architecture?["input_modalities"] as? [String], ["text", "image"])
    // A 1×1 red PNG.
    let image = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="
    let (data, response) = try await post("/v1/chat/completions", [
      "model": id,
      "messages": [["role": "user", "content": [
        ["type": "text", "text": "What color is this image?"],
        ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(image)"]],
      ]]],
      "max_tokens": 16,
    ])
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, String(decoding: data, as: UTF8.self))
  }

  /// A decision model is listed as one, opens on its Try screen instead of the WebUI,
  /// and answers the example request through `/v1/systemone`.
  @MainActor
  func testDecisionModelAnswersOnTryScreen() async throws {
    let app = XCUIApplication()
    app.launch()
    let decision = (repo: "ggml-org/tinyopenjev-for-testing-gguf", quant: "Q8_0")
    try await install(decision, in: app)
    let id = "\(decision.repo):\(decision.quant)"

    let entry = try await models()[id]
    XCTAssertEqual(entry?["tags"] as? [String], ["decision"])
    let architecture = entry?["architecture"] as? [String: Any]
    XCTAssertEqual(architecture?["output_modalities"] as? [String], ["decisions"], "\(String(describing: entry))")

    XCTAssertFalse(app.buttons["chat-\(id)"].exists, "Decision models can't chat")
    let tryButton = app.buttons["try-\(id)"]
    reveal(tryButton, in: app)
    let enabled = NSPredicate(format: "isEnabled == true")
    await fulfillment(of: [expectation(for: enabled, evaluatedWith: tryButton)], timeout: 120)
    tryButton.tap()

    // A model without a draft opens on the example: three questions, one per type.
    let reset = app.buttons["decisionMore"]
    XCTAssertTrue(reset.waitForExistence(timeout: 10), app.debugDescription)
    reset.tap()
    app.buttons["Reset to Example"].tap()
    let run = app.buttons["runDecision"]
    XCTAssertTrue(run.waitForExistence(timeout: 10), app.debugDescription)
    run.tap()
    // The answers open on a page of their own; the list only builds the rows on
    // screen, so the later ones come into view with a swipe.
    XCTAssertTrue(app.navigationBars["Answers"].waitForExistence(timeout: 120), app.debugDescription)
    for key in ["route", "angry", "urgency"] {
      let answer = app.descendants(matching: .any).matching(identifier: "answer-\(key)").firstMatch
      if key == "route" {
        XCTAssertTrue(answer.waitForExistence(timeout: 120), "No answer to \(key)\n\(app.debugDescription)")
      }
      for _ in 0..<5 where !answer.exists { app.swipeUp() }
      XCTAssertTrue(answer.exists, "No answer to \(key)\n\(app.debugDescription)")
    }
    XCTAssertFalse(app.staticTexts["decisionError"].exists)
    // The engine reports the compute time.
    let compute = app.descendants(matching: .any).matching(identifier: "decisionCompute").firstMatch
    for _ in 0..<3 where !compute.exists { app.swipeUp() }
    XCTAssertTrue(compute.exists, app.debugDescription)
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "Decision-answers"
    attachment.lifetime = .keepAlways
    add(attachment)

    // The engine swapped the decision model in.
    let statuses = try await modelStatuses()
    XCTAssertEqual(statuses[id], "loaded", "\(statuses)")

    // Back on the form, the last answers open again without a new run.
    app.navigationBars["Answers"].buttons.firstMatch.tap()
    let showAnswers = app.buttons["showAnswers"]
    XCTAssertTrue(showAnswers.waitForExistence(timeout: 10), app.debugDescription)
    showAnswers.tap()
    XCTAssertTrue(app.navigationBars["Answers"].waitForExistence(timeout: 10), app.debugDescription)
    app.navigationBars["Answers"].buttons.firstMatch.tap()
    app.buttons["Close"].tap()
  }

  /// The Hugging Face token is checked, saved and removed from Settings.
  @MainActor
  func testSettingsKeepTheHuggingFaceToken() {
    let app = XCUIApplication()
    app.launch()
    app.buttons["settings"].tap()
    let saved = app.staticTexts["tokenSaved"]
    if saved.exists { app.buttons["Remove the token"].tap() }

    let field = app.secureTextFields["tokenField"]
    XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
    field.tap()
    field.typeText("not-a-token")
    XCTAssertFalse(app.buttons["saveToken"].isEnabled)
    field.clearAndType("hf_test1234567890")
    app.buttons["saveToken"].tap()
    XCTAssertTrue(saved.waitForExistence(timeout: 5), app.debugDescription)

    // Kept across launches, then removed.
    app.terminate()
    app.launch()
    app.buttons["settings"].tap()
    XCTAssertTrue(saved.waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Models"].exists)
    app.buttons["Remove the token"].tap()
    XCTAssertFalse(saved.exists)
    app.buttons["Done"].tap()
  }

  /// Stops a download midway, resumes it, then lets it finish while the app is in the
  /// background. The model is deleted at the end, so every run downloads it again.
  @MainActor
  func testDownloadStopsResumesAndFinishesInBackground() throws {
    let app = XCUIApplication()
    app.launch()
    let model = (repo: "unsloth/SmolLM2-135M-Instruct-GGUF", quant: "F16")
    let id = "\(model.repo):\(model.quant)"
    let installed = app.descendants(matching: .any).matching(identifier: "installed-\(id)").firstMatch
    XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 15))
    if installed.exists { delete(id, in: app) }

    app.open(URL(string: "llama://install?repo=\(model.repo)&quant=\(model.quant)")!)
    let download = app.alerts.buttons["Download"]
    XCTAssertTrue(download.waitForExistence(timeout: 60), app.debugDescription)
    download.tap()
    let progress = app.staticTexts["downloadProgress"]
    XCTAssertTrue(progress.waitForExistence(timeout: 60), app.debugDescription)
    let receiving = NSPredicate(format: "NOT (label BEGINSWITH %@)", "Zero")
    wait(for: [expectation(for: receiving, evaluatedWith: progress)], timeout: 60)

    app.buttons["Stop"].tap()
    let resume = app.buttons["Resume"]
    XCTAssertTrue(resume.waitForExistence(timeout: 30), app.debugDescription)
    resume.tap()
    // The interrupted row turns back into the downloading one.
    XCTAssertTrue(resume.waitForNonExistence(timeout: 10), app.debugDescription)
    XCTAssertTrue(progress.waitForExistence(timeout: 30), app.debugDescription)

    XCUIDevice.shared.press(.home)
    XCTAssertTrue(app.wait(for: .runningBackgroundSuspended, timeout: 30) || app.state == .runningBackground)
    // The transfer goes on without the app.
    Thread.sleep(forTimeInterval: 15)
    app.activate()
    XCTAssertTrue(installed.waitForExistence(timeout: 600), app.debugDescription)
    delete(id, in: app)
  }

  /// Stops a download, then discards it: the row goes, and the model can be got again.
  @MainActor
  func testDiscardingAStoppedDownloadRemovesIt() throws {
    let app = XCUIApplication()
    app.launch()
    let model = (repo: "unsloth/SmolLM2-135M-Instruct-GGUF", quant: "F16")
    let id = "\(model.repo):\(model.quant)"
    let installed = app.descendants(matching: .any).matching(identifier: "installed-\(id)").firstMatch
    XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 15))
    if installed.exists { delete(id, in: app) }

    app.open(URL(string: "llama://install?repo=\(model.repo)&quant=\(model.quant)")!)
    let download = app.alerts.buttons["Download"]
    XCTAssertTrue(download.waitForExistence(timeout: 60), app.debugDescription)
    download.tap()
    let progress = app.staticTexts["downloadProgress"]
    XCTAssertTrue(progress.waitForExistence(timeout: 60), app.debugDescription)

    app.buttons["Stop"].tap()
    let discard = app.buttons["Discard"]
    XCTAssertTrue(discard.waitForExistence(timeout: 30), app.debugDescription)
    discard.tap()
    XCTAssertTrue(discard.waitForNonExistence(timeout: 10), app.debugDescription)
    XCTAssertFalse(app.buttons["Resume"].exists)
    XCTAssertFalse(progress.exists)
    XCTAssertFalse(installed.exists)
  }

  @MainActor
  private func delete(_ id: String, in app: XCUIApplication) {
    let installed = app.descendants(matching: .any).matching(identifier: "installed-\(id)").firstMatch
    // The context menu offers Delete on every OS; swipe actions on cards need iOS 27.
    reveal(installed, in: app)
    installed.press(forDuration: 1)
    app.buttons["Delete"].tap()
    let confirm = app.buttons["confirmDelete"].firstMatch
    XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
    confirm.tap()
    let gone = NSPredicate(format: "exists == false")
    wait(for: [expectation(for: gone, evaluatedWith: installed)], timeout: 30)
  }

  /// Installs through the same link the llama.app catalog uses, confirming the download,
  /// and returns once the engine lists the model. Checks the engine rather than the
  /// screen: the model list only builds the rows in view, so an installed model further
  /// down has no element. Starts with the engine running.
  @MainActor
  private func install(_ model: (repo: String, quant: String), in app: XCUIApplication) async throws {
    let id = "\(model.repo):\(model.quant)"
    XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 15))
    await waitForEngine()
    guard try await models()[id] == nil else { return }
    app.open(URL(string: "llama://install?repo=\(model.repo)&quant=\(model.quant)")!)
    let download = app.alerts.buttons["Download"]
    XCTAssertTrue(download.waitForExistence(timeout: 60), app.debugDescription)
    download.tap()
    let deadline = Date().addingTimeInterval(600)
    while try await models()[id] == nil {
      guard Date() < deadline else { return XCTFail("\(id) did not install\n\(app.debugDescription)") }
      try await Task.sleep(for: .seconds(2))
    }
  }

  /// Waits for the engine to answer, which it does once it runs.
  private func waitForEngine() async {
    let deadline = Date().addingTimeInterval(120)
    while (try? await models()) == nil {
      guard Date() < deadline else { return XCTFail("The engine did not start") }
      try? await Task.sleep(for: .seconds(1))
    }
  }

  /// Scrolls the model list down until `element` exists: the list only builds the rows
  /// in view.
  @MainActor
  private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<6 where !element.exists { app.swipeUp() }
  }

  private func modelStatuses() async throws -> [String: String] {
    try await models().compactMapValues { ($0["status"] as? [String: Any])?["value"] as? String }
  }

  /// The server's model list, by id.
  private func models() async throws -> [String: [String: Any]] {
    let (data, _) = try await URLSession.shared.data(from: server.appendingPathComponent("models"))
    let list = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let models = list?["data"] as? [[String: Any]] ?? []
    return Dictionary(uniqueKeysWithValues: models.compactMap { model in
      (model["id"] as? String).map { ($0, model) }
    })
  }

  private func post(_ path: String, _ body: [String: Any]) async throws -> (Data, URLResponse) {
    var request = URLRequest(url: server.appendingPathComponent(path))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return try await URLSession.shared.data(for: request)
  }
}

private extension XCUIElement {
  /// Replaces a text field's content.
  func clearAndType(_ text: String) {
    let current = value as? String ?? ""
    typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
  }
}
