//  IntegrationsView
//  Every service and plugin, with its own page.
//
//  Modelled on how an editor presents extensions: a list grouped by what things ARE, and a
//  detail page per item carrying its description, its permissions, its enable/disable control
//  and its configuration. Built-in services appear here alongside anything third-party,
//  because they are the same kind of thing (a seeded plugin) and giving them a separate,
//  nicer screen would be the first step towards a model plugins cannot actually use.
//
//  The permissions list is the part that earns its place. A user deciding whether to enable
//  something should be able to see that ngrok runs a program and talks to api.ngrok.com while
//  the LAN option does neither, and that comparison only exists because both declare it.
//
//  See `docs/EVENTS.md` and `.claude/docs/architecture.md`.

import AppKit
import BBBuiltIns
import BBDiagnostics
import BBInterfaces
import BBServiceKit
import BBSettings
import BBSystem
import BlueBubblesServerCore
import SwiftUI

struct IntegrationsView: View {

  @Bindable var model: AppModel

  var body: some View {
    // The stack lives HERE, not around the whole detail column. This is the only page
    // that pushes anything, and a stack wrapping every page broke the sidebar: a
    // split-view `NavigationLink` is meant to drive the detail column, and the stack
    // intercepted it instead.
    //
    // A stack rather than a sheet, because the detail page needs a real Back button: a
    // modal would strand someone who navigated in to configure a tunnel and then wanted
    // to check a setting behind it.
    NavigationStack(path: $model.detailPath) {
      Group {
        if model.settingsStore == nil {
          ServerStoppedNotice(
            model: model, placement: .page(symbol: "puzzlepiece.extension"),
            purpose: "manage integrations")
        } else {
          list
        }
      }
      .navigationDestination(for: ServiceIdentifier.self) { id in
        if let manifest = IntegrationCatalog.manifest(id), manifest.isUserManageable,
          let store = model.settingsStore
        {
          IntegrationDetailView(manifest: manifest, store: store, model: model)
        }
      }
    }
  }

  private var list: some View {
    SettingsPage {
      ForEach(IntegrationCatalog.categories, id: \.self) { category in
        let manifests = IntegrationCatalog.manifests(in: category)
        if !manifests.isEmpty {
          section(category, manifests)
        }
      }
    }
  }

  private func section(_ category: ServiceCategory, _ manifests: [ServiceManifest]) -> some View {
    // Stated where it applies, rather than discovered by trying. "Only one can be
    // active" is the whole reason picking ngrok turns Cloudflare off.
    // The count belongs on the header rather than being counted by eye, and it
    // is where "you have three of these and none enabled" becomes visible.
    SettingsSection(
      category.displayName,
      subtitle: category.summary
    ) {
      ForEach(Array(manifests.enumerated()), id: \.element.id) { index, manifest in
        if index > 0 { SettingsDivider() }
        NavigationLink(value: manifest.id) {
          row(manifest)
        }
        .buttonStyle(.plain)
      }
    } trailing: {
      HStack(spacing: 8) {
        if category.isExclusive { Tag("one at a time") }
        Text("\(manifests.count)")
          .font(.callout).foregroundStyle(.tertiary)
      }
    }
  }

  private func row(_ manifest: ServiceManifest) -> some View {
    let isEnabled = model.integrations.isEnabled(manifest)
    return HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          // In an exclusive category "enabled" means "the one in use", and a dot says
          // that at a glance where a tag among tags does not. Additive services keep the
          // tag: several can be on, and a row of dots would count rather than point.
          if manifest.category.isExclusive {
            Circle()
              .fill(isEnabled ? Color.green : Color.secondary.opacity(0.25))
              .frame(width: 8, height: 8)
              .accessibilityLabel(isEnabled ? "Selected" : "Not selected")
          }
          Text(manifest.name).font(.body.weight(.medium))
          if manifest.isBuiltIn { Tag("built-in") }
          if ConnectionMethodChoices.isRecommended(manifest) { Tag("recommended") }
          if isEnabled, !manifest.category.isExclusive { Tag("enabled") }
        }
        Text(manifest.summary)
          .font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        // Only for a service that is switched ON and is not running. Switched off already
        // says so through its tag or its dot, and a row reading "Running" on every healthy
        // service is a row people stop reading: at which point the one that says
        // something else is missed too.
        if isEnabled, let status = status(for: manifest) {
          Label(status.text, systemImage: status.symbol)
            .font(.caption)
            .foregroundStyle(status.isProblem ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 12)
      Image(systemName: "chevron.right").foregroundStyle(.tertiary)
    }
    // The whole row is the hit target, not just the text in it.
    .contentShape(Rectangle())
    .padding(.vertical, SettingsMetrics.rowSpacing / 2)
  }

  /// What this service is doing, when that is not simply "running".
  private func status(for manifest: ServiceManifest) -> ServiceStatusSummary.Line? {
    ServiceStatusSummary.line(
      for: model.serviceHealth(manifest.id),
      blockedBy: model.integrations.disabledDependency(of: manifest)?.name
    )
  }
}

// MARK: - Detail

struct IntegrationDetailView: View {

  let manifest: ServiceManifest
  let store: SettingsStore
  @Bindable var model: AppModel

  @State private var isConfirmingReset = false
  @State private var isConfirmingDisable = false
  /// The switch's own position, seeded from the model and re-seeded whenever the model
  /// moves. Not a binding onto the model: a switch bound to state it cannot change until an
  /// async write lands flips, snaps back, and flips again, and the one that asks for
  /// confirmation first snapped back instantly, which read as a switch that refused to
  /// move. Cancel in the dialog sets this back, which is the animation a person expects.
  @State private var enabledSwitch = false
  @State private var resetMessage: String?
  /// Bumped after a reset to rebuild the form, which loads its values once on appear.
  @State private var formGeneration = 0

  /// A service this one needs that is switched off. While there is one, this service
  /// cannot run whatever its own switch says.
  private var blockingDependency: ServiceManifest? {
    model.integrations.disabledDependency(of: manifest)
  }

  /// What it is doing, when that is not simply "running".
  private var status: ServiceStatusSummary.Line? {
    ServiceStatusSummary.line(
      for: model.serviceHealth(manifest.id), blockedBy: blockingDependency?.name)
  }

  var body: some View {
    SettingsPage {
      header
      // Directly under the title: a step only the person can take (a sign-in link, a
      // feature to switch on) is the one thing on this page that matters until it is
      // done, and it is what someone who came here from the notification is looking for.
      attention
      // Above the permissions and the form on purpose: for a connection method that
      // runs someone else's program, "is that program here" is the first question, and
      // configuring a tunnel whose binary is missing is filling in a form for nothing.
      ForEach(manifest.tools, id: \.id) { tool in
        ManagedToolSection(descriptor: tool, model: model)
      }
      permissions
      // The outcome, beside the fields that decide it: a connection method's page is where
      // someone changes a name or a port, and the address is what that changes.
      if manifest.category == .reverseProxy {
        PublishedAddressSection(manifest: manifest, model: model)
      }
      if !manifest.settings.isEmpty { configuration }
    }
    .navigationTitle(manifest.name)
  }

  /// The page's title block, outside a card: it identifies the page rather than being one
  /// more group of settings on it.
  private var header: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          // A breadcrumb rather than a bare title: this page is reached from the
          // settings screen as well as from the list, so it has to say what kind
          // of thing it is without relying on where you came from.
          Text(manifest.category.displayName)
            .font(.callout).foregroundStyle(.secondary)
          Text(manifest.name).font(.largeTitle.weight(.semibold))
          HStack(spacing: 8) {
            Text("Version \(manifest.version)")
            if manifest.isBuiltIn { Tag("built-in") }
            if ConnectionMethodChoices.isRecommended(manifest) { Tag("recommended") }
          }
          .font(.callout).foregroundStyle(.tertiary)
        }
        Spacer(minLength: 12)
        enableControl
      }

      if !manifest.details.isEmpty {
        Text(manifest.details)
          .font(.body)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      // What it is actually doing, beside what it is configured to do. This page showed a
      // toggle and no state at all, so a service stranded behind a switched-off dependency
      // looked identical to one that was working.
      if model.integrations.isEnabled(manifest), let status {
        Label(status.text, systemImage: status.symbol)
          .font(.callout)
          .foregroundStyle(status.isProblem ? Color.orange : Color.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if !manifest.dependencies.isEmpty {
        // Named, not identified. These read as "Needs HTTP API", where they used to read
        // "Needs app.bluebubbles.core.http": a string that means nothing to the person
        // deciding whether to turn something off, and that names no row they can go to.
        // Through the catalog, so a dependency on something loaded from elsewhere is named
        // by its own manifest rather than falling back to its id.
        Label(
          "Needs "
            + manifest.dependencies
            .map { IntegrationCatalog.manifest($0)?.name ?? $0.rawValue }
            .joined(separator: ", "),
          systemImage: "arrow.triangle.branch"
        )
        .font(.callout).foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// What this service is waiting on a person for, on the page where it is configured.
  /// The service withdraws it from here and from the drawer once the step is taken.
  @ViewBuilder
  private var attention: some View {
    let pending = model.alerts.pendingAttention(for: manifest.id)
    if !pending.isEmpty {
      SettingsSection(
        "Needs Your Attention",
        subtitle: "\(manifest.name) cannot finish connecting until this is done."
      ) {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(pending) { alert in
            VStack(alignment: .leading, spacing: 6) {
              Label(alert.title, systemImage: "exclamationmark.triangle.fill")
                .font(.body.weight(.medium))
                .foregroundStyle(.orange)
              Text(alert.body)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
              ForEach(alert.actions, id: \.self) { action in
                // Only the link. The other action every one of these carries is "open
                // settings", and this IS the settings page.
                if case .openURL(let url) = action {
                  HStack(spacing: 10) {
                    Button("Open Link") {
                      NSWorkspace.shared.open(url)
                      Task { await model.alerts.setRead(alert.id, true) }
                    }
                    .controlSize(.small)
                    // Selectable, for a sign-in someone would rather finish on their
                    // phone than in this Mac's browser.
                    Text(url.absoluteString)
                      .font(.caption).foregroundStyle(.tertiary)
                      .textSelection(.enabled)
                      .lineLimit(1).truncationMode(.middle)
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private var enableControl: some View {
    if manifest.category.isExclusive {
      // In an exclusive category, enabling is a CHOICE between siblings rather than a
      // switch: a toggle would leave "off" meaning "nothing is selected", which for a
      // connection method is a server nobody can reach.
      if model.integrations.isEnabled(manifest) {
        Text("Selected").font(.caption.weight(.medium)).foregroundStyle(.green)
      } else {
        Button("Use This") { Task { await model.integrations.select(manifest) } }
          .controlSize(.small)
      }
    } else {
      // A built-in cannot be uninstalled, only switched off, which is why this is a
      // toggle and not a Remove button. Removing something the server ships would leave
      // a gap nothing could fill.
      Toggle("Enabled", isOn: $enabledSwitch)
        .toggleStyle(.switch)
        .labelsHidden()
        // Frozen while a dependency is off, because moving it then decides nothing: this
        // service cannot run either way until that one is back. The reason sits under the
        // header, so the switch is not silently dead.
        .disabled(
          (manifest.isBuiltIn && !IntegrationCatalog.canDisable(manifest))
            || blockingDependency != nil
        )
        .help(
          blockingDependency.map {
            "\(manifest.name) cannot run while \($0.name) is switched off."
          } ?? ""
        )
        // The model's answer, mirrored into the switch. `initial: true` seeds it on appear.
        .onChange(of: model.integrations.isEnabled(manifest), initial: true) { _, isEnabled in
          enabledSwitch = isEnabled
        }
        .onChange(of: enabledSwitch) { _, isOn in
          // A re-seed from the model arrives here too; only a person's move differs from
          // what the model holds.
          guard isOn != model.integrations.isEnabled(manifest) else { return }
          // Switching something ON is never surprising, so it never asks. Only the off
          // direction can have a consequence someone cannot see from here.
          if !isOn, IntegrationCatalog.disableWarning(for: manifest) != nil {
            isConfirmingDisable = true
          } else {
            Task { await applyToggle() }
          }
        }
        .confirmationDialog(
          "Turn off \(manifest.name)?",
          isPresented: $isConfirmingDisable,
          titleVisibility: .visible
        ) {
          Button("Turn Off", role: .destructive) {
            Task { await applyToggle() }
          }
          // Escape and a click outside run the cancel action too, so every way out of the
          // dialog that is not Turn Off puts the switch back.
          Button("Cancel", role: .cancel) {
            enabledSwitch = model.integrations.isEnabled(manifest)
          }
        } message: {
          if let warning = IntegrationCatalog.disableWarning(for: manifest) {
            Text(warning)
          }
        }
    }
  }

  /// Writes the switch's position, then re-seeds the switch from what the model holds.
  ///
  /// The re-seed is for the refused write: `toggle` reports it and leaves the model where it
  /// was, and a model that did not move fires no `onChange`, so without this the switch
  /// would stay on the position the store rejected.
  private func applyToggle() async {
    await model.integrations.toggle(manifest)
    enabledSwitch = model.integrations.isEnabled(manifest)
  }

  private var permissions: some View {
    SettingsSection(
      "Permissions",
      subtitle: "What this can reach on your Mac and on the network."
    ) {
      if manifest.entitlements.isEmpty && manifest.permissions.isEmpty {
        Text("This needs no special access.")
          .font(.callout).foregroundStyle(.secondary)
          .padding(.vertical, 4)
      } else {
        VStack(alignment: .leading, spacing: 12) {
          // macOS permissions first: they are the ones a person has to go and grant, and
          // the ones that cost something to refuse. Nothing enforces them; see
          // `ServicePermission`, so this list IS the feature.
          ForEach(manifest.permissions, id: \.id) { permission in
            Label {
              Text(
                permission.userFacingDescription(
                  namingPermission: PermissionsService.title(for:)
                )
              )
              .fixedSize(horizontal: false, vertical: true)
            } icon: {
              Image(
                systemName: permission.requirement.isRequired
                  ? "lock.fill" : "lock.open"
              )
              .foregroundStyle(permission.requirement.isRequired ? .orange : .secondary)
            }
            .font(.callout)
          }
          ForEach(manifest.entitlements, id: \.self) { entitlement in
            Label {
              // Settings named by their storage key, which is what a person can go
              // and check in the config file, in `--set` and in the logs. The
              // reasoning is on `Entitlement.userFacingDescription`.
              Text(entitlement.userFacingDescription)
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
              Image(
                systemName: entitlement.isSensitive
                  ? "exclamationmark.triangle.fill" : "checkmark.circle"
              )
              .foregroundStyle(entitlement.isSensitive ? .orange : .secondary)
            }
            .font(.callout)
          }
        }
        .padding(.vertical, 4)
      }
    }
  }

  private var configuration: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        if let resetMessage {
          Text(resetMessage).font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
        // Destructive and confirmed, because it clears credentials too: a token
        // someone pasted from a dashboard they would have to go back and find again.
        Button("Reset to Defaults", role: .destructive) { isConfirmingReset = true }
      }
      .padding(.horizontal, 4)

      // `id:` forces the form to rebuild after a reset. It loads its values once in
      // `.task`, so without this the fields would keep showing what was just cleared.
      //
      // Not wrapped in a scroll view of its own: it emits sections into THIS page, so a
      // long manifest scrolls with the rest of the page rather than inside a pane.
      ServiceFormView(manifest: manifest, store: store, model: model)
        .id(formGeneration)
    }
    .confirmationDialog(
      "Reset \(manifest.name) to its defaults?",
      isPresented: $isConfirmingReset,
      titleVisibility: .visible
    ) {
      Button("Reset", role: .destructive) { Task { await reset() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        manifest.fields.contains(where: \.isSecret)
          ? "This clears its settings on this Mac, including any tokens you have "
            + "entered. Nothing is changed on the service's own website."
          : "This clears its settings on this Mac.")
    }
  }

  private func reset() async {
    let cleared: Int
    do {
      cleared = try await ServiceSettingsBridge.resetToDefaults(manifest, store: store)
    } catch {
      await model.report(error, while: "reset \(manifest.name)")
      resetMessage = "The settings could not be cleared. See Alerts for the reason."
      return
    }
    // Says what happened rather than claiming success either way: "nothing to reset" is a
    // real outcome and the button gives no other feedback.
    resetMessage =
      cleared == 0
      ? "Nothing was stored, so nothing changed."
      : "Cleared \(cleared.counted("setting"))."
    formGeneration += 1
  }

}
