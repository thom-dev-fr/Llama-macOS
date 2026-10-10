import Darwin
import Foundation

/// How much memory a model may use on this device. iOS terminates an app whose
/// footprint passes a per-process limit well below physical RAM, so the budget
/// is measured against that limit, not against RAM as on the Mac.
nonisolated enum DeviceMemory {
  /// Physical RAM, in MB. The catalog's memory caps are written against it.
  static let physicalMb = ProcessInfo.processInfo.physicalMemory / 1_048_576

  /// Margin kept inside the limit for what the estimate can't see: the app
  /// itself, the engine's compute buffers, allocation rounding. The same figure
  /// the Mac keeps inside the GPU working set.
  static let slackMb: Double = 1024

  /// The memory a model may use, in MB. An estimate: a model above it may still
  /// load, so the app warns rather than refuses.
  static var budgetMb: Double {
    max(limitMb - slackMb, 0)
  }

  /// The process memory limit, in MB: what is still available plus what the
  /// app already uses, so the figure doesn't shrink while a model is loaded.
  /// The simulator reports no limit; half the Mac's RAM stands in for it.
  static var limitMb: Double {
    let available = UInt64(os_proc_available_memory())
    guard available > 0 else { return Double(physicalMb) / 2 }
    return Double(available + footprintBytes) / 1_048_576
  }

  /// The app's current memory footprint, as iOS counts it against the limit.
  private static var footprintBytes: UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
  }
}
