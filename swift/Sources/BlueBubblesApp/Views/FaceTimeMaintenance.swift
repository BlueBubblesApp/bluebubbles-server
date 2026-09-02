//  FaceTimeMaintenance
//  The "clear up after FaceTime" button, under the Private API settings.
//
//  Exists because the cleanup cannot be fully automatic. Stray links are only invalidatable
//  while they are in FaceTime.app's link snapshot, which is taken at process start and never
//  refreshed — so a link minted since the last restart cannot be cleared until the next one.
//  The automatic sweep runs on helper registration; this is the manual counterpart for
//  someone who wants it gone now.
//
//  It only ever clears links the SERVER created, and never a link made in FaceTime.app.

import BBInterfaces
import BBPrivateAPIContract
import BBSettings
import BBSystem
import BlueBubblesServerCore
import SwiftUI

struct FaceTimeMaintenance: View {

  @Bindable var model: AppModel
  @State private var isWorking = false
  @State private var summary: String?
  @State private var isFailure = false

  var body: some View {
    SettingsSection(
      "FaceTime Maintenance",
      subtitle: "Clear links this server created, and any call the Mac is stuck in. "
        + "Links you made yourself in FaceTime are never touched."
    ) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Orphaned links and calls")
          if let summary {
            Text(summary)
              .font(.caption)
              .foregroundStyle(isFailure ? Color.red : .secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer()
        Button("Clear Now") { Task { await clear() } }
          .disabled(isWorking || !model.phase.isRunning)
      }
    }
  }

  private func clear() async {
    guard let faceTime = await model.faceTime() else { return }
    isWorking = true
    defer { isWorking = false }
    summary = nil
    isFailure = false

    let result = await faceTime.cleanUp(clearAll: true)

    let links = result.links.count
    let calls = result.calls.count
    if links == 0, calls == 0, result.alerts == 0 {
      // A failure and "nothing to do" look identical from the outside, so say which.
      isFailure = result.failure != nil
      summary = result.failure.map { "Nothing cleared — \($0)" } ?? "Nothing to clear."
    } else {
      var parts = ["Cleared \(links) link\(links == 1 ? "" : "s")"]
      if calls > 0 { parts.append("left \(calls) call\(calls == 1 ? "" : "s")") }
      if result.alerts > 0 { parts.append("dismissed a blocking alert") }
      summary = parts.joined(separator: ", ") + "."
    }
  }
}
