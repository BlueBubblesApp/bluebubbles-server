//  HostArchitecture
//  Which builds this Mac can actually execute.
//
//  The question is not "what architecture is this process", and getting those two confused is
//  the bug this file exists to prevent. A server running under Rosetta reports `x86_64` from
//  `uname`, and downloading the Intel build on that basis works — badly. It runs translated,
//  slower, and forever, because nothing would ever notice the machine was Apple Silicon.
//
//  So: the MACHINE's architecture, with translation treated as a fallback rather than as an
//  answer.
//
//  See `.claude/docs/performance.md`.

import BBServiceKit
import Darwin
import Foundation

extension ToolArchitecture {

  /// This Mac's own architecture, regardless of how this process happens to be running.
  ///
  /// Computed once: it cannot change without a reboot into a different computer.
  public static let host: ToolArchitecture = {
    // `sysctl.proc_translated` is 1 when THIS process is being translated, which means the
    // machine underneath is Apple Silicon no matter what `uname` says.
    if isTranslated { return .arm64 }

    var info = utsname()
    guard uname(&info) == 0 else { return .x86_64 }
    let machine = withUnsafePointer(to: &info.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
        String(cString: $0)
      }
    }
    return machine.hasPrefix("arm") ? .arm64 : .x86_64
  }()

  /// Whether this process is running under Rosetta.
  public static let isTranslated: Bool = {
    var translated: Int32 = 0
    var size = MemoryLayout<Int32>.size
    let result = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0)
    // ENOENT on an Intel Mac: the key does not exist there at all, which is itself the
    // answer.
    return result == 0 && translated == 1
  }()

  /// Whether an Intel build could be run on this machine.
  ///
  /// On Apple Silicon that means Rosetta being INSTALLED, which is not a given — it is an
  /// optional download, and a Mac that has never needed it does not have it. Without this
  /// check the fallback produces `Bad CPU type in executable`, which surfaces as a tunnel
  /// that exits immediately for no stated reason.
  public static var canRunIntelBuilds: Bool {
    if host == .x86_64 { return true }
    // The runtime, not the `arch` binary: `/usr/bin/arch` exists on every Mac and says
    // nothing about whether Rosetta is present.
    return FileManager.default.fileExists(
      atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
      || FileManager.default.fileExists(atPath: "/usr/libexec/rosetta/oahd")
  }

  /// The architectures to look for a build in, best first.
  ///
  /// Native always wins. The Intel fallback exists because a vendor can be slow to ship an
  /// arm64 build — cloudflared was, for years — and a translated tunnel is better than no
  /// tunnel. There is no fallback in the other direction: an arm64 binary does not run on an
  /// Intel Mac by any mechanism.
  public static var runnable: [ToolArchitecture] {
    switch host {
    case .arm64: canRunIntelBuilds ? [.arm64, .x86_64] : [.arm64]
    case .x86_64: [.x86_64]
    }
  }
}
