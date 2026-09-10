//  DevicesView
//  Paired devices, as a real manager rather than a list of names.
//
//  The Electron app shows registered FCM tokens with no way to inspect or remove one. This
//  shows what each device actually is (when it was last seen, which payload codec it
//  negotiated) and can revoke it. See `docs/AUTH.md`.

import BBAuth
import SwiftUI

struct DevicesView: View {

  @Bindable var model: AppModel
  @State private var screen: ScreenModel<[EnrolledDevice]>
  /// The device Revoke was pressed for, while the confirmation is up.
  @State private var pendingRevocation: EnrolledDevice?

  init(model: AppModel) {
    self.model = model
    _screen = State(initialValue: ScreenModel { try await Self.read(model) })
  }

  /// Token auth being off is not an error worth showing; the list is simply empty, which
  /// is what a default server should look like here. Distinguished from "the server is not
  /// running", which returns nil and leaves the screen idle.
  ///
  /// A read that fails THROWS, into `ScreenModel`, which is what puts the reason on the
  /// page. Swallowing it would make "the server refused" and "no devices" the same empty
  /// list; see `ScreenModel`.
  @MainActor
  private static func read(_ model: AppModel) async throws -> [EnrolledDevice]? {
    guard let auth = model.security.tokenAuth else { return nil }
    return try await auth.devices()
  }

  private var devices: [EnrolledDevice] { screen.state.value ?? [] }

  var body: some View {
    Group {
      if !model.phase.isRunning {
        ServerStoppedNotice(
          model: model, placement: .page(symbol: "iphone"), purpose: "manage paired devices")
      } else if devices.isEmpty, screen.state.isLoading {
        // Before the empty state, not after it: the list is empty while the read is in
        // flight too, and "No devices" is the wrong answer rather than an early one.
        LoadingNotice(subject: "devices")
      } else if devices.isEmpty, screen.problem == nil {
        // See ScheduledMessagesView: an empty state keyed off the count alone renders
        // over a failed read.
        ContentUnavailableView(
          "No devices",
          systemImage: "iphone.slash",
          description: Text("Devices appear here once a client registers.")
        )
      } else {
        list
      }
    }
    .reloads(screen, following: model)
    .confirmationDialog(
      "Revoke this device?",
      isPresented: Binding(
        get: { pendingRevocation != nil },
        set: { if !$0 { pendingRevocation = nil } }
      ),
      titleVisibility: .visible,
      presenting: pendingRevocation
    ) { device in
      Button("Revoke \(device.name)", role: .destructive) {
        Task { await revoke(device) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { device in
      Text(
        "\(device.name) will be signed out of this server and has to pair again before it "
          + "can connect. Its messages are not affected.")
    }
  }

  private var list: some View {
    ScrollView {
      VStack(spacing: 10) {
        ForEach(devices) { device in
          GlassCard {
            HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: 4) {
                Text(device.name).font(.headline)
                Text(lastSeen(device))
                  .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                  Tag(device.platform)
                  // What the device actually negotiated. A device listing
                  // no codecs is on legacy-v1 by definition, which is the
                  // default rather than a missing value.
                  Tag(device.supportedCodecs.first ?? "legacy-v1")
                  if device.isRevoked { Tag("revoked") }
                }
              }
              // The description reads as one device rather than five fragments: a name,
              // a date, and three bare words like "revoked" that mean nothing on their
              // own. Only this stack: the Revoke button beside it stays a separate
              // element, because combining a row that contains a control swallows it.
              .accessibilityElement(children: .combine)
              Spacer()
              // Confirmed first: revoking makes that phone re-enrol, which is the person's
              // work to undo, not the server's. See the app CLAUDE.md on destructive actions.
              Button("Revoke", role: .destructive) { pendingRevocation = device }
                .controlSize(.small)
                .disabled(screen.isPerforming)
            }
          }
        }
        if let message = screen.problem {
          ScreenErrorLine(message: message)
        }
      }
      .padding(20)
    }
  }

  /// "Never" rather than a formatted epoch zero. A device that registered and never came
  /// back is the interesting case, and 1 January 1970 obscures it.
  private func lastSeen(_ device: EnrolledDevice) -> String {
    guard let lastSeenAt = device.lastSeenAt else { return "Never connected" }
    return "Last seen \(lastSeenAt.formatted(.relative(presentation: .named)))"
  }

  private func revoke(_ device: EnrolledDevice) async {
    guard let auth = model.security.tokenAuth else { return }
    await screen.perform { try await auth.revoke(deviceID: device.id) }
  }
}
