//  MemoryFootprint
//  What this process is actually using, measured against the memory budget.
//
//  The budget is a design constraint with numbers — under 60 MB idle, and no more than
//  +40 MB over idle for a 1000-message query — and CI asserts it. Without a measurement
//  from the kernel, "flat memory curve" has no definition a test can fail on.
//
//  `phys_footprint` is the number to use, not `resident_size`. Resident size counts pages
//  shared with other processes — the dyld shared cache alone is hundreds of megabytes of
//  frameworks every process maps — so it reports a trivial program as enormous and moves when
//  an unrelated process touches the same library. `phys_footprint` is what Activity Monitor
//  shows as "Memory" and what the OS uses for its own pressure decisions, which makes it both
//  the honest number and the one a user would compare against.
//
//  See `.claude/docs/performance.md` and `.claude/docs/workflow.md`.

import Darwin
import Foundation

public enum MemoryFootprint {

  /// Bytes this process is charged for, or nil if the kernel declined to say.
  ///
  /// Nil rather than zero: a failed measurement must not read as "using no memory", which
  /// would make a budget assertion pass for the wrong reason — the exact failure mode a
  /// memory test exists to catch.
  public static func current() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    return UInt64(info.phys_footprint)
  }

  /// Megabytes, for assertions and log lines that a person reads.
  public static func currentMegabytes() -> Double? {
    current().map { Double($0) / 1_048_576 }
  }

  /// Runs `body` and reports how much the footprint grew while it ran.
  ///
  /// The measurement is deliberately taken AFTER a drain rather than at the peak: the
  /// query budget is "+40 MB over idle, **returning to baseline afterwards**", and transient
  /// peak allocation is not what that asserts. A peak measurement would also be dominated by
  /// whatever the allocator had not yet returned, which is noise rather than growth.
  public static func growth<T>(
    during body: () async throws -> T
  ) async rethrows -> (result: T, grewBy: Int64) {
    let before = current() ?? 0
    let result = try await body()

    // One autorelease drain, because Foundation-heavy work parks objects in the pool and
    // measuring before it empties attributes them to the caller permanently.
    autoreleasepool {}
    let after = current() ?? 0

    return (result, Int64(after) - Int64(before))
  }
}
