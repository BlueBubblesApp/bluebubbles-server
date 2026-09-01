//  PermissionsSettings
//  Live permission status with deep links, as a tab of the settings screen.
//
//  Not a sidebar page. Permissions are the answer to "what is this app allowed to do on this
//  Mac", which is a setting; giving them a permanent top-level row spent sidebar space on
//  something most people touch once during setup and never again. The count that made that row
//  worth glancing at moved to a badge on the tab.
//
//  The problem this solves, in the user's words: a permission that was not set up front
//  becomes a mysterious failure later. The current app checks permissions with unreliable
//  probes — `hasFullDiskAccess()` shells out to `defaults read` and string-matches the output
//  — grants them through one-shot prompts, and shows them in one flat panel that does not
//  update.
//
//  Three things make this different:
//    - Status is LIVE. Flipping a toggle in System Settings is reflected within two seconds,
//      so the user sees their action take effect instead of concluding it did not work.
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
        content(permissions: model.permissionList)
          .task { await model.refreshPermissions() }
      } else {
        SettingsSection(
          "Permissions",
          subtitle: "Start the server to check what this Mac has granted."
        ) {
          Label(
            "The server is not running, so these cannot be checked.",
            systemImage: "info.circle"
          )
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.vertical, 4)
        }
      }
    }
  }

  @ViewBuilder
  private func content(permissions: [Permission]) -> some View {
    SettingsSection(
      "Permissions",
      subtitle: "What this app is allowed to do on this Mac. Status updates as you "
        + "change it in System Settings.",
      // Stated so a stale page is visibly stale. Without it, a page that stopped
      // refreshing looks identical to one reporting fresh results.
      trailing: model.permissionsCheckedAt.map { checkedAt in
        AnyView(
          Text("Checked \(checkedAt.formatted(date: .omitted, time: .standard))")
            .font(.callout)
            .foregroundStyle(.tertiary)
        )
      }
    ) {
      if model.unsatisfiedRequiredCount > 0 {
        SettingsFootnote(
          text: "\(model.unsatisfiedRequiredCount) required permission"
            + "\(model.unsatisfiedRequiredCount == 1 ? " is" : "s are") missing. "
            + "The server will run, but the features below will not work.",
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
          status: model.permissions[permission.id] ?? .notDetermined,
          model: model
        )
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

      if status != .granted {
        Text(guidance)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 10) {
          if permission.canPrompt, status == .notDetermined {
            Button("Request Access") {
              Task {
                await model.request(permission.id)
                await model.refreshPermissions()
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
      } else if permission.requiresRelaunch, model.needsRelaunch {
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

  @ViewBuilder
  private var requirementTag: some View {
    switch permission.requirement {
    case .required:
      Text("Required")
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(.red.opacity(0.15), in: Capsule())
    case .recommended:
      Text("Recommended")
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(.orange.opacity(0.15), in: Capsule())
    case .feature(let name):
      Text(name)
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(.blue.opacity(0.15), in: Capsule())
    }
  }

  private var level: StatusDot.Level {
    switch status {
    case .granted: .ok
    case .denied, .restricted: permission.requirement.isRequired ? .bad : .warning
    case .notDetermined, .unknown: .unknown
    }
  }

  private var statusLabel: String {
    switch status {
    case .granted: "Granted"
    case .denied: "Denied"
    case .restricted: "Restricted"
    case .notDetermined: "Not set"
    // Distinct from "not set": the probe could not determine the answer at all, which
    // for Automation means Messages.app was not found.
    case .unknown: "Unknown"
    }
  }

  /// What to actually do, per permission and per state.
  ///
  /// Specific rather than generic. "Grant this permission" tells someone nothing they had
  /// not worked out; "you must add the app yourself, the prompt will not appear" is the
  /// fact that unsticks Full Disk Access.
  private var guidance: String {
    switch permission.id {
    case .fullDiskAccess:
      return """
        macOS will not prompt for this one. Open System Settings, click +, and add \
        BlueBubbles yourself — then relaunch, because the grant only takes effect \
        when the app next starts.
        """
    case .automationMessages:
      return status == .denied
        ? """
        Previously denied. macOS will not ask again, so this has to be re-enabled \
        by hand under Privacy & Security → Automation.
        """
        : "Needed to send messages when the Private API is not available."
    case .systemIntegrityProtection:
      return """
        Read-only. Disabling System Integrity Protection is done from Recovery and \
        is your decision — without it the server still runs, sends and receives; \
        reactions, edit and unsend, typing indicators and group management do not.
        """
    default:
      return status == .denied
        ? "Previously denied. macOS will not ask again; re-enable it in System Settings."
        : permission.why
    }
  }
}
