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
//  The lists are FOLLOWED, not read: `AppModel.accessControl` is the service's own snapshot,
//  streamed on every block, unblock, allowlist edit, recorded failure and (the one nothing
//  else could deliver) automatic expiry. This section used to re-read after its own actions
//  and never otherwise, so a block that lapsed while the page was open stayed listed with
//  "expired" beside it and an Unblock button that acted on an entry already gone. Reading off
//  the model, the way tool statuses are read, is what makes that impossible.
//
//  Emits sections, not a page: the host scrolls.
//
//  See `docs/AUTH.md`.

import BBAuth
import SwiftUI

struct SecurityAdministration: View {

  @Bindable var model: AppModel

  @State private var newAllowEntry = ""
  @State private var newAllowNote = ""
  /// A mutation is in flight. Every button disables on it, so a second click on "Unblock &
  /// Allow" cannot run its two steps again over a row that is already gone.
  @State private var isPerforming = false
  /// The local-network switch's position while its write is in flight. Read before the
  /// list, so the switch does not flip back for the round trip; see `SettingRow.pending`.
  @State private var pendingLocalNetwork: Bool?

  private var blocked: [BlockedClient] { model.accessControl?.blocked ?? [] }
  private var allowed: [AllowedClient] { model.accessControl?.allowed ?? [] }
  private var failures: [AuthFailureRecord] { model.accessControl?.failures ?? [] }

  var body: some View {
    Group {
      if model.phase.isRunning {
        // Configured rather than administered, and the only one here that affects
        // whether traffic is encrypted at all, so it comes first.
        CertificateImportView(model: model)
        blocklist
        allowlist
        recentFailures
      } else {
        ServerStoppedNotice(
          model: model, placement: .section(title: "Access control"),
          purpose: "administer blocks and the allowlist")
      }
    }
  }

  // MARK: - Blocklist

  private var blocklist: some View {
    SettingsSection(
      "Blocked clients",
      subtitle: "Addresses that failed authentication too many times. Automatic blocks "
        + "expire on their own."
    ) {
      if blocked.isEmpty {
        Text("Nothing is blocked.")
          .font(.callout).foregroundStyle(.secondary)
          .padding(.vertical, 4)
      } else {
        ForEach(blocked) { client in
          if client.id != blocked.first?.id { SettingsDivider() }
          blockedRow(client)
        }
      }
    } trailing: {
      if !blocked.isEmpty {
        Button("Clear All", role: .destructive) {
          Task { await mutate { await $0.clearAllBlocks() } }
        }
        .disabled(isPerforming)
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
      // The address and the reason it was blocked belong together; the two unblock
      // buttons beside them stay separate.
      .accessibilityElement(children: .combine)
      Spacer(minLength: 12)
      // Both actions, because they answer different questions. "Unblock" is for a user
      // who mistyped their password; "Unblock and allowlist" is for one whose address
      // keeps tripping the counter and should stop being counted.
      HStack(spacing: 8) {
        Button("Unblock") {
          Task { await mutate { await $0.unblock(id: client.id) } }
        }
        .disabled(isPerforming)
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
        .disabled(isPerforming)
      }
    }
    .padding(.vertical, SettingsMetrics.rowSpacing / 2)
  }

  /// Why it was blocked and for how long, in one line.
  ///
  /// The remaining time matters most: an automatic block always expires, so the common
  /// accidental case resolves itself, and knowing that is the difference between waiting
  /// four minutes and filing a bug. The row leaves the list when the service says the block
  /// has lapsed, so "expired" is never shown against an entry that is still here.
  private func describe(_ client: BlockedClient) -> String {
    var parts = [client.failureCount.counted("failed attempt"), client.reason]
    if let expiresAt = client.expiresAt {
      let remaining = max(0, expiresAt.timeIntervalSinceNow)
      parts.append(
        "expires in \(Duration.seconds(Int(remaining)).formatted(.units(allowed: [.hours, .minutes, .seconds])))"
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
            get: { pendingLocalNetwork ?? allowed.contains { $0.note == Self.localNetworkNote } },
            set: { enabled in
              pendingLocalNetwork = enabled
              Task {
                await mutate { await $0.trustLocalNetwork(enabled) }
                // The service has published the new list by the time `mutate` returns,
                // so the switch falls back to what is actually allowlisted.
                pendingLocalNetwork = nil
              }
            }
          )
        )
        .toggleStyle(.switch)
        .labelsHidden()
        .disabled(isPerforming)
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
            .disabled(
              newAllowEntry.trimmingCharacters(in: .whitespaces).isEmpty || isPerforming)
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
            .disabled(isPerforming)
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
      subtitle: "Including addresses that have not been blocked, a slow, distributed "
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

  /// Applies a change. No re-read: the service publishes the new state to the model before
  /// the call returns, and every list above is read from there.
  ///
  /// The service's own methods do not throw: access control answers "no" by returning a
  /// result rather than by failing, so there is no error to show.
  private func mutate(_ body: @MainActor (AccessControlService) async -> Void) async {
    guard let service = model.security.accessControl else { return }
    isPerforming = true
    defer { isPerforming = false }
    await body(service)
  }
}
