import Foundation

/// Sends Try screen requests to the embedded server's `/v1/systemone`, which loads the
/// named decision model first when another one is in memory.
nonisolated enum DecisionClient {
  struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  /// The answers, with the request and response bodies as sent and received for
  /// copying, and how long it took.
  struct Exchange: Sendable {
    let result: DecisionResult
    let request: Data
    let response: Data
    let timings: Timings
  }

  /// Durations in milliseconds. `load` and `compute` come from the engine's
  /// Server-Timing header, nil if it sent none; `total` is the whole request, as the
  /// app saw it.
  struct Timings: Sendable {
    var load: Double?
    var compute: Double?
    var total: Double

    /// Reads `load;dur=12.3, compute;dur=45.6`.
    init(serverTiming: String?, total: Double) {
      self.total = total
      for metric in (serverTiming ?? "").split(separator: ",") {
        let parts = metric.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let name = parts.first,
          let duration = parts.dropFirst().first(where: { $0.hasPrefix("dur=") }).flatMap({ Double($0.dropFirst(4)) })
        else { continue }
        switch name {
        case "load": load = duration
        case "compute": compute = duration
        default: break
        }
      }
    }
  }

  @concurrent
  static func run(_ draft: DecisionDraft, model: String, images: [Data], on server: URL) async throws -> Exchange {
    var request = URLRequest(url: server.appendingPathComponent("v1/systemone"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    // Loading the model comes first, and takes a while for a large one.
    request.timeoutInterval = 600
    let sent = try JSONSerialization.data(
      withJSONObject: draft.body(model: model, images: images), options: [.sortedKeys])
    request.httpBody = sent

    let clock = ContinuousClock()
    let start = clock.now
    let (data, response) = try await URLSession.shared.data(for: request)
    let total = (clock.now - start) / .milliseconds(1)
    let http = response as? HTTPURLResponse
    let status = http?.statusCode ?? 0
    guard status == 200 else { throw Failure(message: message(in: data, status: status)) }
    do {
      return Exchange(
        result: try JSONDecoder().decode(DecisionResult.self, from: data), request: sent, response: data,
        timings: Timings(serverTiming: http?.value(forHTTPHeaderField: "Server-Timing"), total: total))
    } catch {
      throw Failure(message: "The engine's answer could not be read: \(error.localizedDescription)")
    }
  }

  /// Formatting can include large Base64 images from a request.
  @concurrent
  static func prettyPrinted(_ data: Data) async -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data),
      let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    else { return nil }
    return String(decoding: pretty, as: UTF8.self)
  }

  /// The server's `{"error": {"message": ...}}`, or the status alone.
  private static func message(in data: Data, status: Int) -> String {
    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    if let message = (object?["error"] as? [String: Any])?["message"] as? String {
      return message
    }
    return "The engine answered with status \(status)."
  }
}
