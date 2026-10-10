import Foundation
import LlamaCore
import os.log

/// Probes a model with `llama fit-params` to derive a `MemProfile`.
/// Run once per installed model; the result is cached on disk.
enum MemProfileRunner {

  private static let logger = Logger(subsystem: Logging.subsystem, category: "MemProfileRunner")

  /// Probes a model at `MemProfile.probeContexts` and fits the affine memory
  /// model through both totals (`MemProfile.fit`).
  ///
  /// Takes ~2s per model (two probes). Returns nil on failure.
  /// Supports cancellation — terminates the subprocess if the Task is cancelled.
  static func run(modelPath: String) async -> MemProfile? {
    guard let llamaPath = LlamaBinaries.llamaPath else {
      logger.error("llama binary not found")
      return nil
    }

    let ctxLo = MemProfile.probeContexts.low
    let ctxHi = MemProfile.probeContexts.high

    guard let loMib = await probeTotalMib(llama: llamaPath, modelPath: modelPath, ctx: ctxLo)
    else { return nil }
    guard let hiMib = await probeTotalMib(llama: llamaPath, modelPath: modelPath, ctx: ctxHi)
    else { return nil }

    return MemProfile.fit(totalMibAtLow: loMib, totalMibAtHigh: hiMib)
  }

  /// Runs `llama fit-params -c <ctx> -fitp on` and returns the total MiB
  /// footprint across all devices (sum of model + context + compute columns).
  ///
  /// `-fitp on` writes one line per device to stdout, e.g.:
  ///   MTL0 2402 2734 517
  ///   Host 680 0 538
  /// We sum every numeric column across every row — on Apple Silicon unified
  /// memory every row draws from the same physical RAM, so all rows count
  /// toward the same budget.
  private static func probeTotalMib(
    llama: String, modelPath: String, ctx: UInt32
  ) async -> Int? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: llama)
    process.arguments = ["fit-params", "-m", modelPath, "-c", String(ctx), "-fitp", "on"]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
      try process.run()
    } catch {
      logger.error("Failed to launch llama fit-params: \(error.localizedDescription)")
      return nil
    }

    return await withTaskCancellationHandler {
      // Read both pipes concurrently to avoid buffer-fill deadlocks. stderr
      // receives heavy log spam from the model load; we discard it.
      async let stdoutRead = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
      async let stderrRead = stderrPipe.fileHandleForReading.readDataToEndOfFile()

      let (stdout, stderr) = await (stdoutRead, stderrRead)
      process.waitUntilExit()

      guard process.terminationStatus == 0 else {
        let errOutput = String(decoding: stderr, as: UTF8.self)
        // status 15 = SIGTERM from our cancellation handler, don't log
        if process.terminationStatus != 15 {
          logger.error(
            "llama fit-params (ctx=\(ctx)) exited with status \(process.terminationStatus): \(errOutput.prefix(500))"
          )
        }
        return nil
      }

      let output = String(decoding: stdout, as: UTF8.self)

      // Each device row is `<name> <model> <context> <compute>` — a non-numeric
      // device name followed by three ints. We require that first-token-is-text
      // shape explicitly so a stray all-numeric line (if stderr ever leaks into
      // stdout, or the format changes) can't masquerade as a row.
      var totalMib = 0
      var rowCount = 0
      for line in output.split(separator: "\n") {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count == 4, Int(tokens[0]) == nil,
          let m = Int(tokens[1]), let c = Int(tokens[2]), let cp = Int(tokens[3])
        else { continue }
        totalMib += m + c + cp
        rowCount += 1
      }

      guard rowCount > 0 else {
        logger.error("Failed to parse -fitp output for ctx=\(ctx): \(output.prefix(500))")
        return nil
      }

      return totalMib
    } onCancel: {
      if process.isRunning {
        process.terminate()
      }
    }
  }
}
