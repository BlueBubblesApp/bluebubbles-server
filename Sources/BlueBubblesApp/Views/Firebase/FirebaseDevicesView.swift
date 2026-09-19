//  FirebaseDevicesView
//  The phones and tablets registered for push notifications.
//
//  This is the `device` table: one row per FCM registration token, written by a client
//  calling `POST /api/v1/device` and removed by the sender when FCM reports a token is no
//  longer registered. It is NOT the token-auth enrolment list, which is what the sidebar's
//  Devices page read for as long as it existed — see `FirebaseDetail` for how that went.
//
//  A sub-page of Firebase rather than a page of its own, and gated on the project being set
//  up, because the list is meaningless without one: an FCM token is issued BY a project and
//  every row is dropped when the project changes.
//
//  ## The list is followed, not polled
//
//  A client re-registers on every launch and after every token rotation, and the sender
//  prunes a row the moment FCM rejects its token — a device vanishing from this list is how
//  somebody learns their phone stopped being reachable. None of that is an event on the bus,
//  so the table is observed (`DeviceObservation.swift`) and this page keys its own read on
//  the counter that observation moves. The rows are read HERE, through `ScreenModel`, so a
//  read that fails says so rather than rendering as an empty list.
//
//  See `Sources/BlueBubblesApp/CLAUDE.md`.

import BBAppStore
import SwiftUI

struct FirebaseDevicesView: View {

  @Bindable var model: AppModel
  @State private var screen: ScreenModel<[Device]>
  /// The device Remove was pressed for, while the confirmation is up.
  @State private var pendingRemoval: Device?

  init(model: AppModel) {
    self.model = model
    _screen = State(initialValue: ScreenModel { try await Self.read(model) })
  }

  /// Nil until the server is running, which is what keeps "not started yet" out of the
  /// error path; see `ScreenModel.read`.
  ///
  /// A read that fails THROWS, into `ScreenModel`. `(try? …) ?? []` here would make "the
  /// database refused" and "no phone has registered" the same empty list, which is the
  /// exact failure the page this replaces shipped with.
  @MainActor
  private static func read(_ model: AppModel) async throws -> [Device]? {
    guard let devices = model.delivery.pushDevices else { return nil }
    return try await devices.all()
  }

  private var devices: [Device] { screen.state.value ?? [] }

  var body: some View {
    Group {
      if !model.phase.isRunning {
        ServerStoppedNotice(
          model: model, placement: .page(symbol: "iphone"),
          purpose: "see registered devices")
      } else if devices.isEmpty, screen.state.isLoading {
        // Ahead of the empty state: the list is empty while the read is in flight too, and
        // "No devices registered" is the wrong answer rather than an early one.
        LoadingNotice(subject: "registered devices")
      } else if devices.isEmpty, screen.problem == nil {
        // `problem == nil` guards it, as on every list here: a table that could not be READ
        // is also empty, and the sentence below would then be a confident lie.
        ContentUnavailableView(
          "No devices registered",
          systemImage: "iphone.slash",
          description: Text(
            "A device appears here when a BlueBubbles client registers for notifications "
              + "with this server.")
        )
      } else {
        list
      }
    }
    .navigationTitle(FirebaseDetail.devices.title)
    // Two triggers, and the second is the point: the phase, so pressing Start reads, and
    // the counter the table observation moves, so a client registering over HTTP or a
    // pruned token updates this page without it asking. Never a timer.
    .reloads(screen, following: model, alsoOn: model.pushDevicesVersion)
    // Confirmed, and the rule it is weighed against says one click: the server made this
    // row, not the person. It confirms anyway because of what removing it DOES — that phone
    // stops receiving notifications, silently, from here until its client next registers,
    // which is on its own schedule and not one this server can promise. A block expires on
    // its own and is re-made by the next failed login; this is neither.
    .confirmationDialog(
      "Remove this device?",
      isPresented: Binding(
        get: { pendingRemoval != nil },
        set: { if !$0 { pendingRemoval = nil } }
      ),
      titleVisibility: .visible,
      presenting: pendingRemoval
    ) { device in
      Button("Remove \(device.name)", role: .destructive) {
        Task { await remove(device) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { device in
      Text(
        "\(device.name) stops receiving notifications until its client registers again. "
          + "Nothing on the device itself is changed, and no message is affected.")
    }
  }

  private var list: some View {
    SettingsPage {
      ForEach(devices, id: \.identifier) { device in
        GlassCard {
          HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
              Text(device.name).font(.headline)
              Text(DeviceRowSummary.lastSeen(device.lastActive))
                .font(.caption).foregroundStyle(.secondary)
              // Abbreviated on purpose; see `DeviceRowSummary.shortToken`.
              Text(DeviceRowSummary.shortToken(device.identifier))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
              HStack(spacing: 6) {
                Tag(DeviceRowSummary.codec(device.supportedCodecs))
                if device.publicKey != nil { Tag("encrypted") }
              }
            }
            // The description reads as one device rather than five fragments: a name, a
            // date, a scrap of token and a bare word like "encrypted" that means nothing on
            // its own. Only this stack: the Remove button beside it stays a separate
            // element, because combining a row that contains a control swallows it.
            .accessibilityElement(children: .combine)
            Spacer()
            Button("Remove", role: .destructive) { pendingRemoval = device }
              .controlSize(.small)
              .disabled(screen.isPerforming)
          }
        }
      }
      if let message = screen.problem {
        ScreenErrorLine(message: message)
      }
    }
  }

  private func remove(_ device: Device) async {
    guard let devices = model.delivery.pushDevices, let id = device.id else { return }
    // No reload afterwards: the table observation sees the delete and moves the counter
    // this page is keyed on, which is the same path a client's own registration takes.
    await screen.perform { _ = try await devices.remove(id: id) }
  }
}
