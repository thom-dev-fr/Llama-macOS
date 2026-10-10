import Foundation
import LlamaCore

extension Model {
  /// Human-readable total file size for the metadata line.
  var totalSize: String {
    Format.gigabytes(fileSize)
  }
}
