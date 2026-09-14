//  FaceTimeMaintenance
//  The "clear up after FaceTime" button, under the Private API settings.
//
//  Exists because the cleanup cannot be fully automatic. Stray links are only invalidatable
//  while they are in FaceTime.app's link snapshot, which is taken at process start and never
//  refreshed, so a link minted since the last restart cannot be cleared until the next one.
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
  /// Whether the confirmation is up. See the dialog below for why there is one.
  @State private var isConfirming = false

  var body: some View {
    SettingsSection(
      "FaceTime Maintenance",
      subtitle: "Clear links this server created, and leave any call this Mac is in. "
        + "Links you made yourself in FaceTime are never touched; a call you are on "
        + "will be ended, so this asks first."
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
        Button("Clear Now") { isConfirming = true }
          .disabled(isWorking || !model.phase.isRunning)
      }
    }
    // CONFIRMED, because this button can end a call somebody is on.
    //
    // It reads as tidying up after the server, and for links that is all it is. But it also
    // leaves every ANSWERED call the Mac is in that no hand-off watcher is managing, and it
    // cannot tell one the server got stuck in from one a person is sitting in at this Mac:
    // both are answered calls with no watcher. So somebody on a call who opens this tab and
    // presses the button drops that call, with no warning and no undo.
    //
    // The project's rule is that a destructive action confirms when it destroys something a
    // person made, and a conversation in progress is squarely that.
    .confirmationDialog(
      "Clear FaceTime links and calls?",
      isPresented: $isConfirming,
      titleVisibility: .visible
    ) {
      Button("Clear Links and Leave Calls", role: .destructive) {
        Task { await clear() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This invalidates every link this server created and LEAVES ANY CALL this Mac is "
          + "currently in, including one you are on right now. Links you made yourself in "
          + "FaceTime are not touched.")
    }
  }

  private func clear() async {
    guard let faceTime = await model.messaging.faceTime() else { return }
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
      summary = result.failure.map { "Nothing cleared: \($0)" } ?? "Nothing to clear."
    } else {
      var parts = ["Cleared \(links.counted("link"))"]
      if calls > 0 { parts.append("left \(calls.counted("call"))") }
      if result.alerts > 0 { parts.append("dismissed a blocking alert") }
      summary = parts.joined(separator: ", ") + "."
    }
  }
}
