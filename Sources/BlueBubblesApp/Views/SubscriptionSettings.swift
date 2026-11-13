//  SubscriptionSettings
//  Where a person enters a license key, and sees what it bought them.
//
//  The page answers three questions in the order somebody arrives with them: what am I paying
//  for, what state is it in, and what do I do about it. Everything it SAYS comes from
//  `SubscriptionPolicy`, which is off the view so the sentences can be asserted: the difference
//  between "your subscription ended" and "we could not confirm your subscription" is the whole
//  point of the design underneath, and it would be a shame to lose it in a `switch` inside a
//  `body` nothing can call.
//
//  ## It reads, it does not poll
//
//  The status is a server read that can fail, so it goes through `ScreenModel` and keys on the
//  server phase. There is no timer and no stream: this value moves when the daily refresh runs
//  or when somebody on THIS PAGE does something, and both of those re-read explicitly. A lapse
//  that happens while nobody is looking reaches the person through the alert centre, which is
//  where `LicenseService` already puts it.
//
//  ## The key goes in and never comes back
//
//  `license_key` is a secret: it is written through the settings store and there is no method
//  anywhere that reads one back, on purpose. So the field shows what is typed and then clears
//  itself, and "a license is installed" is inferred from the status rather than from the key.
//
//  See `Sources/BlueBubblesApp/CLAUDE.md`.

import BBCore
import BBInterfaces
import BBLicense
import BBPrivateAPICatalog
import BBSettings
import SwiftUI

struct SubscriptionSettings: View {

  @Bindable var model: AppModel
  @State private var screen: ScreenModel<SubscriptionReport>
  /// What is being typed. Cleared the moment it is submitted; see the header.
  @State private var keyField = ""
  @State private var isWorking = false
  /// What the last action said, if it said anything. Nil on success: a page that announces
  /// every success trains people to ignore it.
  @State private var actionMessage: String?
  @State private var isConfirmingRemoval = false

  init(model: AppModel) {
    self.model = model
    _screen = State(initialValue: ScreenModel { await model.subscription.report() })
  }

  /// A `switch`, and not the `else if` chain it replaces. That chain had four branches and no
  /// final `else`, so the state the page OPENS in — running, nothing read yet — matched
  /// nothing and `body` was `EmptyView`. See `SubscriptionPolicy.Page`: an empty body also
  /// took the `.task` below with it, so the page never read and never filled in.
  var body: some View {
    Group {
      switch SubscriptionPolicy.page(isRunning: model.phase.isRunning, state: screen.state) {
      case .stopped:
        ServerStoppedNotice(
          model: model, placement: .section(title: "Subscription"),
          purpose: "see your subscription")
      case .showing(let report):
        content(for: report)
      case .loading:
        LoadingNotice(subject: "subscription")
      case .unreadable(let failure):
        NoticeCard(
          symbol: "exclamationmark.triangle", title: "Could not read the subscription",
          tone: .problem, messages: [failure]
        ) {
          EmptyView()
        }
      }
    }
    .reloads(screen, following: model)
  }

  @ViewBuilder
  private func content(for report: SubscriptionReport) -> some View {
    let presentation = SubscriptionPolicy.presentation(for: report)

    NoticeCard(
      symbol: presentation.symbol,
      title: presentation.headline,
      tone: presentation.tone,
      messages: [presentation.detail]
    ) {
      HStack(spacing: 8) {
        ForEach(presentation.actions, id: \.self) { action in
          button(for: action)
        }
      }
    }

    if let actionMessage {
      NoticeCard(
        symbol: "info.circle", title: "License", tone: .attention, messages: [actionMessage]
      ) {
        EmptyView()
      }
    }

    SettingsSection(
      "License key",
      subtitle: report.tier == nil
        ? "Paste the key from your purchase confirmation."
        : "Entering a different key replaces the one on this Mac."
    ) {
      SettingsWideRow(
        title: "Key",
        help: "Stored in the Keychain. It is never shown again and never sent anywhere but "
          + "the BlueBubbles license service."
      ) {
        HStack(spacing: 8) {

          SecureField("XXXX-XXXX-XXXX-XXXX-XXXX", text: $keyField)
            .textFieldStyle(.roundedBorder)
            .onSubmit { Task { await activate() } }
          Button("Activate") { Task { await activate() } }
            .disabled(keyField.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
        }
      }
    }

    SubscriptionFeatureList(model: model, report: report)
  }

  @ViewBuilder
  private func button(for action: SubscriptionPolicy.Action) -> some View {
    switch action {
    case .subscribe:
      Link("Subscribe", destination: URL(string: LicenseLinks.purchase)!)
    case .checkNow:
      Button("Check now") { Task { await check() } }.disabled(isWorking)
    case .remove:
      Button("Remove from this Mac", role: .destructive) { isConfirmingRemoval = true }
        .disabled(isWorking)
        .confirmationDialog(
          "Remove this license from this Mac?",
          isPresented: $isConfirmingRemoval, titleVisibility: .visible
        ) {
          Button("Remove", role: .destructive) { Task { await remove() } }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text(
            "Paid features switch off here. The subscription itself is untouched and can be "
              + "activated on another Mac.")
        }
    }
  }

  // MARK: - Actions

  /// Writes the key, then exchanges it immediately.
  ///
  /// The exchange is the point: the service's timer would otherwise get to it up to a day
  /// later, and somebody who has just pasted a key would watch the page go on saying "no
  /// subscription" with no way to tell whether it worked.
  private func activate() async {
    let key = keyField.trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty else { return }
    isWorking = true
    defer { isWorking = false }
    actionMessage = nil

    do {
      // Never `try?`: a settings write that fails silently here leaves somebody believing
      // they have a subscription they have not got.
      try await model.settings.set(Settings.licenseKey, to: key)
    } catch {
      actionMessage = DiagnosticText.sentence(for: error)
      return
    }
    keyField = ""
    await exchangeAndReload()
  }

  private func check() async {
    isWorking = true
    defer { isWorking = false }
    await exchangeAndReload()
  }

  private func exchangeAndReload() async {
    let outcome = await asOperator { await model.subscription.refresh() }
    actionMessage = outcome.flatMap(SubscriptionPolicy.message(for:))
    await screen.reload()
  }

  private func remove() async {
    isWorking = true
    defer { isWorking = false }
    do {
      try await asOperator { try await model.subscription.remove() }
      actionMessage = nil
    } catch {
      actionMessage = DiagnosticText.sentence(for: error)
    }
    await screen.reload()
  }
}

/// What the subscription adds, drawn from the capability catalog rather than from a list
/// typed into this file, and drawn by the same component as the Private API page's card.
///
/// The catalog already knows which capabilities are part of the paid tier, and
/// `SubscriptionCatalogTests` keeps that honest against the route table. A hand-written list
/// here would be a third description of the same decision, and the one nothing checks.
///
/// Only the paid capabilities are listed: the free ones are on the Private API page, and
/// repeating them here would make the subscription look like it bought them. The picker
/// answers "what would I get on a different macOS", because several paid features need a
/// newer release than somebody deciding whether to subscribe may be running. It starts on
/// this Mac's release and is not stored: it is a question asked on this visit.
private struct SubscriptionFeatureList: View {

  let model: AppModel
  let report: SubscriptionReport

  @State private var macOSMajor = PrivateAPICapability.currentMacOSMajor

  private var entries: [FeatureListEntry] {
    PrivateAPICapability.subscriptionListing(
      macOSMajor: macOSMajor,
      privateAPIConnected: model.privateAPIPresence.showsAvailableFeatures,
      tier: report.tier)
  }

  var body: some View {
    SettingsSection(
      report.tier == nil ? "What a subscription adds" : "Included with your subscription",
      subtitle: "Everything else the server does is free, and stays free."
    ) {
      CollapsibleFeatureList(entries: entries)
        // A different release is a different list, so the fold resets rather than keeping
        // however far the previous one had been opened.
        .id(macOSMajor)
    } trailing: {
      Picker("macOS", selection: $macOSMajor) {
        ForEach(PrivateAPICapability.comparableReleases(), id: \.self) { major in
          Text(releaseLabel(major)).tag(major)
        }
      }
      .labelsHidden()
      .fixedSize()
    }
  }

  private func releaseLabel(_ major: Int) -> String {
    let name = PrivateAPICapability.releaseName(major)
    return major == PrivateAPICapability.currentMacOSMajor ? "\(name), this Mac" : name
  }
}
