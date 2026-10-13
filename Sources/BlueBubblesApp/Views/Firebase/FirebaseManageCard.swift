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
  /// Whether the pointer is over the registered-devices row; see the row for why it needs
  /// more than a chevron to read as one.
  @State private var isHoveringDevices = false
  /// The remote-restart switch's position while its write is in flight, so it does not flip
  /// back for the round trip; see `OptimisticWrite`. Let go when the run settles, which it
  /// does on success and on failure alike; not on `isBusy`, because this write never sets an
  /// activity.
  @State private var pendingRemoteRestart: Bool?

  private var setup: FirebaseSetupModel { model.firebaseSetup }
  private var status: PushStatus? { setup.status }

  var body: some View {
    TitledCard("Manage") {
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

      // The way into the registered list, and the only way: it is a sub-page of this
      // one. It sits inside THIS card, which the page draws only once there is a service
      // account, and that is the gate rather than a check of its own. An FCM token is
      // issued by a project and every row is dropped when the project changes, so a
      // device list with no project behind it is a page that can only ever be empty.
      //
      // Drawn as the same navigable row Integrations uses (`ManifestRow`: a tinted glyph, a
      // sentence saying where it goes, the count, and a chevron) rather than as a label
      // with a number beside it, which is what it was and which read as a statistic. Three
      // signals, because one was not enough here: this row sits among buttons and a
      // toggle rather than in a list of its own, so a bare chevron has nothing to rhyme
      // with. The hover highlight and the link cursor are the other two, and they are the
      // ones that answer "is this a control?" before anybody clicks to find out.
      //
      // The count comes from the same `status` the Send Test button reads, so the row and
      // the button above it cannot disagree about whether anything has registered.
      NavigationLink(value: FirebaseDetail.devices) {
        ManifestRow(
          symbol: FirebaseDetail.devices.symbol,
          title: FirebaseDetail.devices.title,
          summary: "See what has registered for notifications, and remove a device that is "
            + "no longer yours.",
          showsChevron: true
        ) {
          Text((status?.registeredDevices ?? 0).counted("device"))
            .font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        // The whole row is the hit target, not just the text in it, and the shape the
        // highlight is drawn in is the shape that takes the click.
        .contentShape(
          RoundedRectangle(cornerRadius: SettingsMetrics.rowCornerRadius, style: .continuous)
        )
        .background {
          if isHoveringDevices {
            RoundedRectangle(cornerRadius: SettingsMetrics.rowCornerRadius, style: .continuous)
              .fill(Color.primary.opacity(0.06))
          }
        }
      }
      .buttonStyle(.plain)
      .linkCursor()
      // Unanimated. A row that fades under the pointer reads as slower than the pointer,
      // which is the opposite of the reassurance a hover highlight exists to give.
      .onHover { isHoveringDevices = $0 }
      .help("See and remove the devices registered for notifications")

      Divider()

      // The control for the Firebase command channel: the one place in the
      // application that changes the setting. A `SettingsRow`, so the switch, its
      // explanation and its accessible name are laid out the way every other switch in
      // the app is.
      SettingsRow(
        title: "Allow clients to restart this server",
        help: """
          Clients can write a restart request into your Firebase project and this \
          server acts on it. Turning this off stops the server polling for those \
          requests at all. Leave it on if you use the restart button in the app.
          """,
        controlWidth: nil
      ) {
        Toggle(
          "Allow clients to restart this server",
          isOn: .optimistic(
            status?.remoteRestartEnabled ?? true, pending: $pendingRemoteRestart
          ) { enabled in
            setup.setRemoteRestart(enabled, push: model.delivery.push)
            // The run reports its own outcome, success or failure, on the card; this only
            // waits for it to end so the held position is let go at the same moment.
            await setup.settle()
          }
        )
        .toggleStyle(.switch)
        .labelsHidden()
        .disabled(setup.isBusy)
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
