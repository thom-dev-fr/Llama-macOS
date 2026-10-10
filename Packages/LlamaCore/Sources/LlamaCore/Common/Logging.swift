import Foundation

public enum Logging {
  #if DEBUG
    public static let subsystem = "app.llama.Llama.dev"
  #else
    public static let subsystem = "app.llama.Llama"
  #endif
}
