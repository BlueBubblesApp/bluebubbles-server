//  SecurityAdministration
//  Blocklist and allowlist administration, as part of the Security settings tab.
//
//  Rate limiting without an unblock path is a support burden waiting to happen, so access
//  control is designed as an administered system rather than a silent filter. This is the
//  administration.
//
//  It sits under the settings that CAUSE it rather than on a page of its own. "Failures before
//  block" and the list of clients that tripped it are one subject, and splitting them across a
//  sidebar page and a settings section meant tuning the threshold in one place and discovering
//  its effect in another.
//
//  Emits sections, not a page — the host scrolls.
//
//  See `docs/AUTH.md`.

import BBAuth
import SwiftUI

struct SecurityAdministration: View {

  @Bindable var model: AppModel

  @State private var blocked: [BlockedClient] = []
  @State private var allowed: [AllowedClient] = []
  @State private var failures: [AuthFailureRecord] = []
  @State private var newAllowEntry = ""
  @State private var newAllowNote = ""
  @State private var error: String?

  var body: some View {
    Group {
      if model.phase.isRunning {
        // Configured rather than administered, and the only one here that affects
        // whether traffic is encrypted at all — so it comes first.
        CertificateImportView()
        blocklist
        allowlist
        recentFailures
      } else {
        SettingsSection(
          "Access control",
          subtitle: "Start the server to administer blocks and the allowlist."
        ) {
          Label(
            "The server is not running, so access control cannot be read.",
            systemImage: "info.circle"
          )
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.vertical, 4)
        }
      }
    }
    .task { await reload() }
  }

  // MARK: - Blocklist

  private var blocklist: some View {
    SettingsSection(
      "Blocked clients",
      subtitle: "Addresses that failed authentication too many times. Automatic blocks "
        + "expire on their own.",
      trailing: blocked.isEmpty
        ? nil
        : AnyView(
          Button("Clear All", role: .destructive) {
            Task { await mutate { await $0.clearAllBlocks() } }
          }
        )
    ) {
      if blocked.isEmpty {
        Text("Nothing is blocked.")
          .font(.callout).foregroundStyle(.secondary)
          .padding(.vertical, 4)
      } else {
        ForEach(Array(blocked.enumerated()), id: \.element.id) { index, client in
          if index > 0 { SettingsDivider() }
          blockedRow(client)
        }
      }
    }
  }

  private func blockedRow(_ client: BlockedClient) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 20) {
      VStack(alignment: .leading, spacing: 4) {
        Text(client.address).font(.system(.body, design: .monospaced))
        Text(describe(client))
          .font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 12)
      // Both actions, because they answer different questions. "Unblock" is for a user
      // who mistyped their password; "Unblock and allowlist" is for one whose address
      // keeps tripping the counter and should stop being counted.
      HStack(spacing: 8) {
        Button("Unblock") {
          Task { await mutate { await $0.unblock(id: client.id) } }
        }
        Button("Unblock & Allow") {
          Task {
            await mutate {
              await $0.unblock(id: client.id)
              _ = await $0.allow(
                cidr: client.address,
                note: "Unblocked from the Security tab"
              )
            }
          }
        }
      }
    }
    .padding(.vertical, SettingsMetrics.rowSpacing / 2)
  }

  /// Why it was blocked and for how long, in one line.
  ///
  /// The remaining time matters most: an automatic block always expires, so the common
  /// accidental case resolves itself, and knowing that is the difference between waiting
  /// four minutes and filing a bug.
  private func describe(_ client: BlockedClient) -> String {
    var parts = ["\(client.failureCount) failed attempt(s)", client.reason]
    if let expiresAt = client.expiresAt {
      let remaining = expiresAt.timeIntervalSinceNow
      parts.append(
        remaining > 0
          ? "expires in \(Duration.seconds(Int(remaining)).formatted(.units(allowed: [.hours, .minutes, .seconds])))"
          : "expired"
      )
    } else {
      parts.append("permanent")
    }
    if client.offenceCount > 1 { parts.append("blocked \(client.offenceCount) times before") }
    return parts.joined(separator: " · ")
  }

  // MARK: - Allowlist

  private var allowlist: some View {
    SettingsSection(
      "Allowlist",
      subtitle: "An address or CIDR block here is never counted and never blocked."
    ) {
      // The one-click case, because a LAN-only user has little to gain from blocking
      // and much to lose from a false positive.
      SettingsRow(
        title: "Trust my local network",
        help: "Allowlists the private address ranges in one step."
      ) {
        Toggle(
          "",
          isOn: Binding(
            get: { allowed.contains { $0.note == Self.localNetworkNote } },
            set: { enabled in
              Task { await mutate { await $0.trustLocalNetwork(enabled) } }
            }
          )
        )
        .toggleStyle(.switch)
        .labelsHidden()
      }

      SettingsDivider()

      SettingsWideRow(
        title: "Add an address",
        help: "A single address, or a CIDR block such as 192.168.1.0/24."
      ) {
        HStack(spacing: 10) {
          TextField("192.168.1.0/24", text: $newAllowEntry)
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .frame(maxWidth: 220)
          TextField("Note (optional)", text: $newAllowNote)
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
          Button("Add") { add() }
            .disabled(newAllowEntry.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if let error {
          SettingsFootnote(text: error, symbol: "xmark.circle", tone: .error)
        }
      }

      if allowed.isEmpty {
        SettingsDivider()
        Text("Nothing is allowlisted.")
          .font(.callout).foregroundStyle(.secondary)
          .padding(.vertical, 4)
      } else {
        ForEach(allowed) { entry in
          SettingsDivider()
          HStack(spacing: 12) {
            Text(entry.cidr).font(.system(.body, design: .monospaced))
            if let note = entry.note {
              Text(note).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Remove") {
              Task { await mutate { await $0.disallow(id: entry.id) } }
            }
          }
          .padding(.vertical, SettingsMetrics.rowSpacing / 2)
        }
      }
    }
  }

  private func add() {
    let entry = newAllowEntry.trimmingCharacters(in: .whitespaces)
    guard !entry.isEmpty else { return }
    Task {
      await mutate {
        _ = await $0.allow(cidr: entry, note: newAllowNote.isEmpty ? nil : newAllowNote)
      }
      newAllowEntry = ""
      newAllowNote = ""
    }
  }

  private static let localNetworkNote = "Local network"

  // MARK: - Recent failures

  /// Failures from addresses that are NOT blocked.
  ///
  /// This is the part that makes an attack visible before it trips anything: a slow
  /// distributed guess never crosses the threshold from any one address, so the blocklist
  /// stays empty while the attempt is plainly here.
  private var recentFailures: some View {
    SettingsSection(
      "Recent authentication failures",
      subtitle: "Including addresses that have not been blocked — a slow, distributed "
        + "guess never crosses the threshold from any one of them."
    ) {
      if failures.isEmpty {
        Text("None recorded.")
          .font(.callout).foregroundStyle(.secondary)
          .padding(.vertical, 4)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(failures.prefix(50)) { failure in
            HStack(spacing: 12) {
              Text(failure.address ?? "unknown")
                .font(.system(.callout, design: .monospaced))
                .frame(width: 150, alignment: .leading)
              Text(failure.path).font(.callout).foregroundStyle(.secondary)
              Spacer(minLength: 12)
              Text(failure.at.formatted(date: .omitted, time: .standard))
                .font(.callout).foregroundStyle(.secondary)
            }
          }
        }
        .padding(.vertical, 4)
      }
    }
  }

  // MARK: - Plumbing

  private func reload() async {
    guard let service = model.accessControl else { return }
    blocked = await service.blockedClients()
    allowed = await service.allowedClients()
    failures = await service.failures(limit: 100)
  }

  /// Applies a change and re-reads. Reading back rather than mutating local state keeps
  /// the page showing what the service actually holds — including a block that expired
  /// while the window was open.
  private func mutate(_ body: (AccessControlService) async -> Void) async {
    guard let service = model.accessControl else { return }
    await body(service)
    await reload()
  }
}
