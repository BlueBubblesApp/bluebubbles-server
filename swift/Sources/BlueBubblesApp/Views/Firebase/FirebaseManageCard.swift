//  FirebaseManageCard
//  What a set-up server can do: send a test, re-check the security rules, allow or refuse
//  remote restarts, and disconnect. Disconnect confirms here, on the card that offers it.

import AppKit
import BBInterfaces
import BBPushKit
import BlueBubblesServerCore
import SwiftUI
import UniformTypeIdentifiers

struct FirebaseManageCard: View {

  @Bindable var model: AppModel
  @State private var confirmingDisconnect = false
  /// The remote-restart switch's position while its write is in flight, so it does not flip
  /// back for the round trip; see `SettingRow.pending`. Cleared when the run reports an
  /// outcome, which it does on success and on failure alike; not on `isBusy`, because this
  /// write never sets an activity.
  @State private var pendingRemoteRestart: Bool?

  private var setup: FirebaseSetupModel { model.firebaseSetup }
  private var status: PushStatus? { setup.status }

  var body: some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 10) {
        Text("Manage").font(.headline)

        let noDevices = (status?.registeredDevices ?? 0) == 0

        HStack {
          Button("Send Test Notification") { setup.sendTest(push: model.delivery.push) }
            .disabled(setup.isBusy || noDevices)
            // On the control itself, so hovering the greyed-out button answers
            // "why is this disabled?" where the question is actually asked. The
            // explanation in body text below reads as unrelated commentary rather
            // than as the reason.
            .help(
              noDevices
                ? "No device has registered for notifications yet, so there is "
                  + "nowhere to send a test."
                : "Send a test notification to every registered device.")
          Button("Check Security Rules") { setup.repairRules(push: model.delivery.push) }
            .disabled(setup.isBusy)
            .help(
              "Re-check your project's Firebase rules and lock them down if "
                + "they have become too permissive.")
          Spacer()
          Button("Disconnect", role: .destructive) { confirmingDisconnect = true }
            .disabled(setup.isBusy)
        }

        if noDevices {
          // Names the BUTTON, so the sentence is visibly about the disabled control
          // rather than a general remark about devices.
          Label {
            Text(
              """
              “Send Test Notification” is unavailable because no device has \
              registered with this server yet. Open BlueBubbles on your phone \
              and connect it to this server, then come back.
              """
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "iphone.slash").foregroundStyle(.secondary)
          }
        }

        Divider()

        // The control for the Firebase command channel: the one place in the
        // application that changes the setting.
        Toggle(
          isOn: Binding(
            get: { pendingRemoteRestart ?? status?.remoteRestartEnabled ?? true },
            set: {
              pendingRemoteRestart = $0
              setup.setRemoteRestart($0, push: model.delivery.push)
            }
          )
        ) {
          Text("Allow clients to restart this server")
        }
        .disabled(setup.isBusy)
        // `start` clears the outcome before the run and every run ends by reporting one, so
        // a new id is the end of the write. The nil in between is the start of it.
        .onChange(of: setup.outcome?.id) { _, id in
          if id != nil { pendingRemoteRestart = nil }
        }

        Text(
          """
          Clients can write a restart request into your Firebase project and this \
          server acts on it. Turning this off stops the server polling for those \
          requests at all. Leave it on if you use the restart button in the app.
          """
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .confirmationDialog(
      "Disconnect Firebase from this server?",
      isPresented: $confirmingDisconnect,
      titleVisibility: .visible
    ) {
      Button("Disconnect", role: .destructive) { setup.disconnect(push: model.delivery.push) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        """
        Notifications will stop being delivered to closed apps until Firebase is set \
        up again. Your Firebase project itself is not changed, and everything else, \
        the socket, webhooks and the API, keeps working.
        """)
    }
  }
}
