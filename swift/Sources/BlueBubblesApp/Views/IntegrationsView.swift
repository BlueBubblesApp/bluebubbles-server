//  IntegrationsView
//  Every service and plugin, with its own page.
//
//  Modelled on how an editor presents extensions: a list grouped by what things ARE, and a
//  detail page per item carrying its description, its permissions, its enable/disable control
//  and its configuration. Built-in services appear here alongside anything third-party,
//  because they are the same kind of thing — a seeded plugin — and giving them a separate,
//  nicer screen would be the first step towards a model plugins cannot actually use.
//
//  The permissions list is the part that earns its place. A user deciding whether to enable
//  something should be able to see that ngrok runs a program and talks to api.ngrok.com while
//  the LAN option does neither, and that comparison only exists because both declare it.
//
//  See `docs/EVENTS.md` and `.claude/docs/architecture.md`.

import BBBuiltIns
import BBInterfaces
import BBServiceKit
import BBSettings
import BlueBubblesServerCore
import SwiftUI

struct IntegrationsView: View {

  @Bindable var model: AppModel

  var body: some View {
    // The stack lives HERE, not around the whole detail column. This is the only page
    // that pushes anything, and a stack wrapping every page broke the sidebar — a
    // split-view `NavigationLink` is meant to drive the detail column, and the stack
    // intercepted it instead.
    //
    // A stack rather than a sheet, because the detail page needs a real Back button: a
    // modal would strand someone who navigated in to configure a tunnel and then wanted
    // to check a setting behind it.
    NavigationStack(path: $model.detailPath) {
      Group {
        if model.settingsStore == nil {
          ContentUnavailableView(
            "Server not running",
            systemImage: "puzzlepiece.extension",
            description: Text("Start the server to manage integrations.")
          )
        } else {
          list
        }
      }
      .navigationDestination(for: ServiceIdentifier.self) { id in
        if let manifest = IntegrationCatalog.manifest(id),
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
    SettingsSection(
      category.displayName,
      subtitle: category.summary,
      // Stated where it applies, rather than discovered by trying. "Only one can be
      // active" is the whole reason picking ngrok turns Cloudflare off.
      trailing: AnyView(
        HStack(spacing: 8) {
          if category.isExclusive {
            Text("one at a time")
              .font(.caption)
              .padding(.horizontal, 8).padding(.vertical, 3)
              .background(.secondary.opacity(0.15), in: Capsule())
          }
          // The count belongs on the header rather than being counted by eye, and it
          // is where "you have three of these and none enabled" becomes visible.
          Text("\(manifests.count)")
            .font(.callout).foregroundStyle(.tertiary)
        }
      )
    ) {
      ForEach(Array(manifests.enumerated()), id: \.element.id) { index, manifest in
        if index > 0 { SettingsDivider() }
        NavigationLink(value: manifest.id) {
          row(manifest)
        }
        .buttonStyle(.plain)
      }
    }
  }

  private func row(_ manifest: ServiceManifest) -> some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(manifest.name).font(.body.weight(.medium))
          if manifest.isBuiltIn { Tag("built-in") }
          if model.integrations.isEnabled(manifest) { Tag("enabled") }
        }
        Text(manifest.summary)
          .font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 12)
      Image(systemName: "chevron.right").foregroundStyle(.tertiary)
    }
    // The whole row is the hit target, not just the text in it.
    .contentShape(Rectangle())
    .padding(.vertical, SettingsMetrics.rowSpacing / 2)
  }

}

// MARK: - Detail

struct IntegrationDetailView: View {

  let manifest: ServiceManifest
  let store: SettingsStore
  @Bindable var model: AppModel

  @State private var isConfirmingReset = false
  @State private var isConfirmingDisable = false
  @State private var resetMessage: String?
  /// Bumped after a reset to rebuild the form, which loads its values once on appear.
  @State private var formGeneration = 0

  var body: some View {
    SettingsPage {
      header
      // Above the permissions and the form on purpose: for a connection method that
      // runs someone else's program, "is that program here" is the first question, and
      // configuring a tunnel whose binary is missing is filling in a form for nothing.
      ForEach(manifest.tools, id: \.id) { tool in
        ManagedToolSection(descriptor: tool, model: model)
      }
      permissions
      if !manifest.settings.isEmpty { configuration }
    }
    .navigationTitle(manifest.name)
  }

  /// The page's title block, outside a card — it identifies the page rather than being one
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

      if !manifest.dependencies.isEmpty {
        Label(
          "Needs " + manifest.dependencies.map(\.rawValue).joined(separator: ", "),
          systemImage: "arrow.triangle.branch"
        )
        .font(.callout).foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var enableControl: some View {
    if manifest.category.isExclusive {
      // In an exclusive category, enabling is a CHOICE between siblings rather than a
      // switch — a toggle would leave "off" meaning "nothing is selected", which for a
      // connection method is a server nobody can reach.
      if model.integrations.isEnabled(manifest) {
        Text("Selected").font(.caption.weight(.medium)).foregroundStyle(.green)
      } else {
        Button("Use This") { Task { await model.integrations.select(manifest) } }
          .controlSize(.small)
      }
    } else {
      // A built-in cannot be uninstalled, only switched off — which is why this is a
      // toggle and not a Remove button. Removing something the server ships would leave
      // a gap nothing could fill.
      Toggle(
        "Enabled",
        isOn: Binding(
          get: { model.integrations.isEnabled(manifest) },
          set: { _ in
            // Switching something ON is never surprising, so it never asks. Only the
            // off direction can have a consequence someone cannot see from here.
            if model.integrations.isEnabled(manifest),
              IntegrationCatalog.disableWarning(for: manifest) != nil
            {
              isConfirmingDisable = true
            } else {
              Task { await model.integrations.toggle(manifest) }
            }
          }
        )
      )
      .toggleStyle(.switch)
      .labelsHidden()
      .disabled(!manifest.isBuiltIn ? false : !IntegrationCatalog.canDisable(manifest))
      .confirmationDialog(
        "Turn off \(manifest.name)?",
        isPresented: $isConfirmingDisable,
        titleVisibility: .visible
      ) {
        Button("Turn Off", role: .destructive) {
          Task { await model.integrations.toggle(manifest) }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        if let warning = IntegrationCatalog.disableWarning(for: manifest) {
          Text(warning)
        }
      }
    }
  }

  private var permissions: some View {
    SettingsSection(
      "Permissions",
      subtitle: "What this can reach on your Mac and on the network."
    ) {
      if manifest.entitlements.isEmpty {
        Text("This needs no special access.")
          .font(.callout).foregroundStyle(.secondary)
          .padding(.vertical, 4)
      } else {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(Array(manifest.entitlements.enumerated()), id: \.offset) { _, entitlement in
            Label {
              // Named the way the settings screen names them. The composition
              // root is the only place that can join a manifest's raw keys to
              // the first-party settings registry.
              Text(
                entitlement.userFacingDescription(
                  namingSettings: Settings.label(forKey:)
                )
              )
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
        // Destructive and confirmed, because it clears credentials too — a token
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
      : "Cleared \(cleared) setting\(cleared == 1 ? "" : "s")."
    formGeneration += 1
  }

}
