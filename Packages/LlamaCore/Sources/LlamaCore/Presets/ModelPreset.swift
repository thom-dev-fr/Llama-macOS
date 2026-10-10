import Foundation

/// `models.ini`: one `[section]` per model, keyed by model id, whose keys are
/// `llama serve` options without the leading dashes. The Mac hands the file to
/// `llama serve --models-preset`; the iOS engine reads it with the same
/// upstream parser. Both apps generate their sections here, so a model gets the
/// same settings on either.
public enum ModelPreset {
  /// One `[section]` and its keys, in the order they were written.
  ///
  /// Order is preserved rather than using a dictionary so that a section the
  /// app doesn't generate can be passed through looking like what the user
  /// typed -- these files get hand-edited and diffed.
  public struct Section: Sendable {
    public var name: String
    public var pairs: [(key: String, value: String)]

    public init(name: String, pairs: [(key: String, value: String)] = []) {
      self.name = name
      self.pairs = pairs
    }

    /// Sets `key`, replacing an existing entry in place or appending a new one.
    /// In-place replacement keeps app-generated keys in their original position
    /// when a user overrides one.
    public mutating func set(_ key: String, _ value: String) {
      if let index = pairs.firstIndex(where: { $0.key == key }) {
        pairs[index].value = value
      } else {
        pairs.append((key: key, value: value))
      }
    }

    /// Removes `key` if present.
    public mutating func remove(_ key: String) {
      pairs.removeAll { $0.key == key }
    }

    public func value(_ key: String) -> String? {
      pairs.first { $0.key == key }?.value
    }

    public func serialized() -> String {
      var out = "[\(name)]\n"
      for pair in pairs {
        out += "\(pair.key) = \(pair.value)\n"
      }
      return out + "\n"
    }
  }

  /// The app's own sections, derived purely from the cache scan and memory
  /// profiling -- before any user overrides are applied. A model without a
  /// context tier that fits, or without files on disk, gets no section.
  /// `ctxSizeOverride` is the `ctx-size` the user's overrides will set for a
  /// model, if any, so the batch sizes that track the context can follow it.
  public static func sections(
    for models: [Model], paths: [String: ResolvedPaths],
    contextTier: (Model) -> ContextTier?, largeBatch: Bool,
    ctxSizeOverride: (Model) -> String? = { _ in nil }
  ) -> [Section] {
    var sections: [Section] = []

    for model in models {
      // Use the effective tier (user selection or max compatible)
      guard let tier = contextTier(model) else { continue }

      guard let paths = paths[model.id] else { continue }

      var section = Section(name: model.id)
      section.set("model", paths.modelFile)
      section.set("ctx-size", "\(tier.rawValue)")

      if let mmprojPath = paths.mmprojFile {
        section.set("mmproj", mmprojPath)
      }

      // Wire up speculative decoding -- a free speedup on models that ship a
      // draft head (Qwen3.6/3.8 etc.). Two shapes: a separate sidecar
      // (`dflash-….gguf` or `mtp-….gguf`, passed as the draft model), or an
      // MTP head embedded in the main weights (reused via its own MTP context,
      // no draft file). Sidecar wins when both look present. Each kind gets
      // its own draft depth (`DraftHead.draftNMax`).
      if let draftKind = paths.draftSidecarKind ?? (paths.usesMTP ? .mtp : nil) {
        section.set("spec-type", draftKind.specType)
        if let sidecar = paths.draftSidecarFile {
          section.set("spec-draft-model", sidecar)
        }
        section.set("spec-draft-n-max", "\(draftKind.draftNMax)")
      }

      // Larger batches pay off on devices with plenty of memory.
      if largeBatch {
        section.set("ubatch-size", "2048")
      }

      // What kind of model this is, for clients reading `/v1/models`: the
      // OpenAI-style listing has no field for it, and its `architecture`
      // modalities read text-in/text-out for every kind alike.
      // llama-server passes `tags` through to each listing entry verbatim
      // (it doesn't route on them), so a client can offer only `chat` models
      // in a chat picker. Untagged models -- written by earlier app versions
      // -- were all chat models, so clients can read a missing tag as `chat`.
      section.set("tags", model.kind.rawValue)

      // llama-server only serves `/v1/embeddings` for a model started with
      // `--embeddings`. The flag also restricts the instance to embedding
      // (it can't generate), which is all an embedding model does anyway.
      if model.kind == .embedding {
        section.set("embeddings", "true")
      }

      // Some models have to take each input in one batch (embedding models,
      // and decision models like Laya and Clef -- see
      // `ResolvedPaths.batchesWholeInput`), so the longest input they accept
      // is the batch size, not the context ("input is too large to process.
      // increase the physical batch size"). Left at the defaults that's 512
      // tokens (2048 with the large ubatch above), well under the context.
      // Sizing both batches to the context makes the context the real input
      // limit. It costs memory, so these models stay at the default context
      // (see `Model.effectiveCtxTier`). A `ctx-size` in the user's overrides
      // is followed, so raising it there raises the input limit with it.
      if paths.batchesWholeInput {
        let ctx = ctxSizeOverride(model) ?? "\(tier.rawValue)"
        section.set("batch-size", ctx)
        section.set("ubatch-size", ctx)
      }

      sections.append(section)
    }
    return sections
  }

  /// Minimal INI parse: `[section]` headers and `key = value` lines.
  ///
  /// Comments (`;` or `#`) and blank lines are dropped rather than preserved --
  /// the output is a generated file users aren't meant to edit, so carrying
  /// their comments into it would invite editing the wrong file. Keys before
  /// any section header are ignored: `models.ini` has no global section, so
  /// they'd have nowhere to go.
  public static func parse(_ text: String) -> [Section] {
    var sections: [Section] = []

    for rawLine in text.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }

      if line.hasPrefix("[") && line.hasSuffix("]") {
        let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
          sections.append(Section(name: name, pairs: []))
        }
        continue
      }

      // `value` may itself contain `=` (e.g. `chat-template-kwargs`), so split
      // on the first separator only.
      guard let separator = line.firstIndex(of: "="), !sections.isEmpty else { continue }
      let key = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
      let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
      if key.isEmpty { continue }

      sections[sections.count - 1].set(key, value)
    }

    return sections
  }

  /// Applies user overrides to app-generated sections.
  ///
  /// Matching sections are merged per-key, so overriding `temp` doesn't require
  /// restating the `model` and `mmproj` paths. Sections that match nothing the
  /// app generated are appended verbatim -- that's what lets someone define a
  /// model the scan can't produce, such as a draft model from another repo.
  public static func merge(_ generated: [Section], overrides: [Section]) -> [Section] {
    var merged = generated
    var indexByName: [String: Int] = [:]
    for (index, section) in merged.enumerated() {
      indexByName[section.name] = index
    }

    for override in overrides {
      if let index = indexByName[override.name] {
        for pair in override.pairs {
          merged[index].set(pair.key, pair.value)
        }
      } else {
        indexByName[override.name] = merged.count
        merged.append(override)
      }
    }

    return merged
  }
}
