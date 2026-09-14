//  PermissionsSettings
//  Live permission status with deep links, as a tab of the settings screen.
//
//  Not a sidebar page. Permissions are the answer to "what is this app allowed to do on this
//  Mac", which is a setting; giving them a permanent top-level row spent sidebar space on
//  something most people touch once during setup and never again. The count that made that row
//  worth glancing at moved to a badge on the tab.
//
//  The problem this solves, in the user's words: a permission that was not set up front
//  becomes a mysterious failure later.
//
//  Three things this page does about it:
//    - Status is LIVE. Flipping a toggle in System Settings is reflected within two seconds,
//      so the user sees their action take effect instead of concluding it did not work. The
//      fast cadence is not free and not automatic: `permissionsLiveUpdates` is what asks for
//      it, and it lapses when this page goes away.
//    - Each row deep-links to the exact pane, not "open System Settings and find it".
//    - Full Disk Access says plainly that the app must be added by hand AND relaunched, with
//      buttons for both. That is the step people most often get half-right.
//
//  See `docs/AUTH.md`.

import BBServiceKit
import BBSystem
import SwiftUI

struct PermissionsSettings: View {

  @Bindable var model: AppModel

  var body: some View {
    Group {
      if model.phase.isRunning {
        content(permissions: model.permissions.list)
          .task { await model.permissions.refresh() }
          .permissionsLiveUpdates(model.permissions)
      } else {
        ServerStoppedNotice(
          model: model, placement: .section(title: "Permissions"),
          purpose: "check what this Mac has granted")
      }
    }
  }

  @ViewBuilder
  private func content(permissions: [Permission]) -> some View {
    // Stated so a stale page is visibly stale. Without it, a page that stopped
    // refreshing looks identical to one reporting fresh results.
    SettingsSection(
      "Permissions",
      subtitle: "What this app is allowed to do on this Mac. Status updates as you "
        + "change it in System Settings."
    ) {
      if model.permissions.unsatisfiedRequiredCount > 0 {
        SettingsFootnote(
          // Phrased so the count leads and no verb has to agree with it: "Missing 1
          // required permission" reads the same as "Missing 3 required permissions".
          text: "Missing "
            + model.permissions.unsatisfiedRequiredCount.counted("required permission")
            + ". The server will run, but the features below will not work.",
          kind: .required,
          symbol: "exclamationmark.triangle.fill",
          tone: .warning
        )
        .padding(.bottom, 4)
        SettingsDivider()
      }

      ForEach(Array(permissions.enumerated()), id: \.element.id) { index, permission in
        if index > 0 { SettingsDivider() }
        PermissionRow(
          permission: permission,
          status: model.permissions.statuses[permission.id] ?? .notDetermined,
          model: model
        )
      }
    } trailing: {
      if let checkedAt = model.permissions.checkedAt {
        Text("Checked \(checkedAt.formatted(date: .omitted, time: .standard))")
          .font(.callout)
          .foregroundStyle(.tertiary)
      }
    }
  }
}

struct PermissionRow: View {

  let permission: Permission
  let status: PermissionStatus
  @Bindable var model: AppModel

  @Environment(\.openURL) private var openURL

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 20) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(permission.title).font(.body.weight(.medium))
            requirementTag
          }
          // Always shown, granted or not. Someone deciding whether to grant
          // Full Disk Access to a background app deserves the reason in front
          // of them, not in a doc.
          Text(permission.why)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 12)
        StatusDot(level: level, label: statusLabel)
      }
      // Name, reason and state as one stop. Read separately, the status was orphaned from
      // the permission it belonged to: swiping a page of these gave a list of names and
      // then a list of the word "Granted", with nothing pairing them up. The buttons below
      // are outside this stack and stay reachable.
      .accessibilityElement(children: .combine)

      if status != .granted {
        Text(guidance)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 10) {
          if permission.canPrompt, status == .notDetermined {
            Button("Request Access") {
              Task {
                await model.permissions.request(permission.id)
                await model.permissions.refresh()
              }
            }
            .buttonStyle(.borderedProminent)
          }

          if let pane = permission.settingsPane {
            Button("Open System Settings") { openURL(pane) }
          }

          if permission.requiresRelaunch {
            // The drag target. Adding the app to Full Disk Access means
            // finding the bundle in Finder, and "it's in Applications" is
            // not help when the app was run from a build directory.
            Button("Reveal App in Finder") {
              NSWorkspace.shared.activateFileViewerSelecting(
                [Bundle.main.bundleURL]
              )
            }
          }
        }
      } else if permission.requiresRelaunch, model.permissions.needsRelaunch {
        // Only once the grant is actually detected. Offering a relaunch before
        // then would restart the app to no effect and lose the user's place.
        HStack(spacing: 10) {
          Text("Relaunch to apply this permission.").font(.callout)
          Button("Relaunch") { model.relaunch() }
            .buttonStyle(.borderedProminent)
        }
      }
    }
    .padding(.vertical, SettingsMetrics.rowSpacing / 2)
  }

  private var requirementTag: some View {
    switch permission.requirement {
    case .required: Tag("Required", tint: .red)
    case .recommended: Tag("Recommended", tint: .orange)
    case .feature(let name): Tag(name, tint: .blue)
    }
  }

  private var level: StatusDot.Level {
    switch status {
    case .granted: .ok
    case .denied, .restricted: permission.requirement.isRequired ? .bad : .warning
    case .notDetermined, .unknown: .unknown
    }
  }

  private var statusLabel: String { PermissionGuidance.statusLabel(status) }

  private var guidance: String {
    PermissionGuidance.guidance(for: permission, status: status)
  }
}
