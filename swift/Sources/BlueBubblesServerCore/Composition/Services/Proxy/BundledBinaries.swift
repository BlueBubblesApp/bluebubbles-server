//  BundledBinaries
//  Where a BUNDLED tunnel executable is found — the last fallback behind `ToolManager`.

import Foundation

/// Where a BUNDLED tunnel executable is found.
///
/// No longer the primary source: `ToolManager` downloads and version-manages these, and this
/// is the last thing it falls back to. Kept rather than deleted for two cases that are both
/// real — a build that deliberately ships its binaries (offline or enterprise installs), and
/// a development tree with one dropped next to the executable.
///
/// `Packaging/build-app.sh` still copies nothing here, so on a stock build this returns nil
/// and the managed install is what serves every user.
public enum BundledBinaries {
  /// Inside the app bundle when packaged; alongside the executable in development.
  static func path(for name: String) -> String? {
    let candidates = [
      Bundle.main.resourceURL?.appendingPathComponent("bin/\(name)").path,
      Bundle.main.bundleURL.deletingLastPathComponent()
        .appendingPathComponent(name).path,
    ].compactMap { $0 }

    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }
}
