//  DevicesView
//  Paired devices, as a real manager rather than a list of names.
//
//  The Electron app shows registered FCM tokens with no way to inspect or remove one. This
//  shows what each device actually is — when it was last seen, which payload codec it
//  negotiated — and can revoke it. See `docs/AUTH.md`.

import BBAuth
import SwiftUI

struct DevicesView: View {

  @Bindable var model: AppModel
  @State private var devices: [EnrolledDevice] = []
  @State private var error: String?

  var body: some View {
    Group {
      if !model.phase.isRunning {
        ContentUnavailableView(
          "Server not running",
          systemImage: "iphone",
          description: Text("Start the server to manage paired devices.")
        )
      } else if devices.isEmpty {
        ContentUnavailableView(
          "No devices",
          systemImage: "iphone.slash",
          description: Text("Devices appear here once a client registers.")
        )
      } else {
        list
      }
    }
    .task { await reload() }
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
              Spacer()
              Button("Revoke", role: .destructive) {
                Task { await revoke(device) }
              }
              .controlSize(.small)
            }
          }
        }
        if let error {
          Text(error).font(.caption).foregroundStyle(.red)
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

  private func reload() async {
    guard let auth = model.tokenAuth else { return }
    do { devices = try await auth.devices() } catch {
      // Token auth being off is not an error worth showing — the list is simply
      // empty, which is what a default server should look like here.
      devices = []
    }
  }

  private func revoke(_ device: EnrolledDevice) async {
    guard let auth = model.tokenAuth else { return }
    do {
      try await auth.revoke(deviceID: device.id)
      await reload()
    } catch {
      self.error = String(describing: error)
    }
  }
}

struct Tag: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(.caption2)
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(.secondary.opacity(0.15), in: Capsule())
  }
}
