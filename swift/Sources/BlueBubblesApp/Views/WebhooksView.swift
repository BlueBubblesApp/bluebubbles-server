//  WebhooksView
//  Webhook registration, and the API address clients need.
//
//  Both halves of this page are services that can be switched off on the Integrations
//  screen, and each panel says so and offers the switch. Rendering the controls regardless
//  would accept and store an endpoint that is never called, and offer a copy button for an
//  address nothing is listening on. Saying so is the only reason a page can talk about a
//  feature it does not own.
//
//  Registration is a sheet rather than an inline field because there is a second thing to say
//  about a webhook: WHICH events it wants. An inline field cannot ask, which subscribes every
//  endpoint to everything. See `WebhookEditor`.

import BBBuiltIns
import BBEvents
import BBInterfaces
import BBOpenAPI
import BBServiceKit
import BBSettings
import BlueBubblesServerCore
import SwiftUI

struct WebhooksView: View {

  @Bindable var model: AppModel
  @Environment(\.openWindow) private var openWindow
  @State private var screen: ScreenModel<Registrations>
  @State private var isAdding = false
  @State private var testing: Set<Int64> = []
  /// The webhook the editor is open on. Separate from `isAdding` so the same sheet can be
  /// presented empty or filled without a nil-means-new state that both cases share.
  @State private var editing: EditTarget?
  /// The endpoint Remove was pressed for, while the confirmation is up.
  @State private var pendingRemoval: Webhook?

  /// The page's two reads as one value.
  ///
  /// A snapshot rather than two `@State` properties because they are read together and
  /// are only meaningful together: the address card describes the listener the endpoints
  /// below it are registered against. Read separately, a failure partway through left a
  /// fresh list beside a stale address with nothing saying which was which.
  ///
  /// Delivery outcomes are NOT in here. They are followed from the tracker's stream into
  /// `AppModel.webhookDeliveries` and read from there (see `WebhookObservation.swift`)
  /// so a delivery updates its row without this page re-reading the table.
  struct Registrations: Sendable {
    var webhooks: [Webhook] = []
    var address = "-"
  }

  init(model: AppModel) {
    self.model = model
    _screen = State(initialValue: ScreenModel { try await Self.read(model) })
  }

  /// Nil until the server is running, which is what keeps "not started yet" out of the
  /// error path; see `ScreenModel.read`.
  @MainActor
  private static func read(_ model: AppModel) async throws -> Registrations? {
    guard let serverAdmin = model.serverAdmin, let settings = model.settings else {
      return nil
    }
    let port = await settings.get(Settings.socketPort)
    let configured = await settings.get(Settings.serverAddress)
    return Registrations(
      // Not `(try? …) ?? []`: a list the server refused to produce and a server with no
      // endpoints registered must not arrive here as the same empty array.
      webhooks: try await serverAdmin.webhooks(),
      address: configured.isEmpty ? "http://localhost:\(port)" : configured
    )
  }

  private var webhooks: [Webhook] { screen.state.value?.webhooks ?? [] }
  private var deliveries: [Int64: WebhookDeliveryState] { model.webhookDeliveries }
  private var address: String { screen.state.value?.address ?? "-" }

  /// `.sheet(item:)` needs an `Identifiable`, and `Webhook` is a database record whose
  /// `id` is optional until it is stored. The URL is the identity the database itself
  /// enforces (registrations upsert on it) so it is the key here and for the rows.
  private struct EditTarget: Identifiable {
    let hook: Webhook
    var id: String { hook.url }
  }

  var body: some View {
    Group {
      if !model.phase.isRunning {
        ServerStoppedNotice(
          model: model, placement: .page(symbol: "network"), purpose: "manage webhooks")
      } else {
        content
      }
    }
    // Re-read on appear: the switch lives on another screen, and a page that decides
    // whether a feature is on when the app launched would show a stale answer for the
    // rest of the session.
    .task(id: model.phase.isRunning) { await model.integrations.refresh() }
    // And again whenever the webhook TABLE changes, whichever path wrote it: this page,
    // a client over HTTP, which the model follows from the repository's observation. This
    // page used to re-read on a ten-second sleep for the same effect; it was the one timer
    // in the app. Delivery outcomes are not a reason to re-read: they arrive on their own
    // stream and the rows read them from the model.
    .reloads(screen, following: model, alsoOn: model.webhookRegistrationsVersion)
    .sheet(isPresented: $isAdding) {
      WebhookEditor(model: model, initial: nil, existing: webhooks) {
        Task { await screen.reload() }
      }
    }
    .sheet(item: $editing) { target in
      WebhookEditor(model: model, initial: target.hook, existing: webhooks) {
        Task { await screen.reload() }
      }
    }
    .confirmationDialog(
      "Remove this webhook?",
      isPresented: Binding(
        get: { pendingRemoval != nil },
        set: { if !$0 { pendingRemoval = nil } }
      ),
      titleVisibility: .visible,
      presenting: pendingRemoval
    ) { hook in
      Button("Remove", role: .destructive) { Task { await remove(hook) } }
      Button("Cancel", role: .cancel) {}
    } message: { hook in
      Text(
        "Nothing more will be delivered to \(hook.url). Its address and event list are "
          + "not kept, so adding it back means entering them again.")
    }
    // A toolbar entry as well as the link in the address card. The link sits next to the
    // address because that is where someone who has just copied it is about to want the
    // reference; the toolbar is for everyone who came to this tab for the API rather than
    // for webhooks, and did not find a link styled as body text inside a card.
    .toolbar {
      Button {
        openWindow(id: APIDocsView.windowID)
      } label: {
        Label("API Reference", systemImage: "curlybraces")
      }
      .help("Open the generated API reference")
    }
  }

  private var content: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        GlassCard {
          VStack(alignment: .leading, spacing: 6) {
            Text("API address").font(.headline)

            if let manifest = httpManifest, !model.integrations.isEnabled(manifest) {
              // The address is deliberately not shown here. Copying an address
              // that nothing is listening on is the one action this card exists
              // for, and it would fail silently on the client's side.
              FeatureDisabledNotice(
                manifest: manifest,
                model: model,
                consequence: "The REST API is not listening, so no client can "
                  + "reach this server. Any reverse proxy that depends on it "
                  + "is stopped too."
              )
            } else {
              // The em dash is "not read yet", not an address, so it goes in as the
              // PLACEHOLDER, which is what withholds the copy button. Shown as the value
              // with the button disabled beside it, it would read as a copy that is
              // unavailable rather than as a value that is not there.
              CopyableValue(address == "-" ? "" : address, placeholder: "-")
              Text("This is what clients connect to.")
                .font(.caption).foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 2)

            // The reference belongs on this page and not in the sidebar: someone who has
            // just copied the address is, right then, about to go and look up what to
            // send to it. It sits OUTSIDE the disabled branch above on purpose: the
            // document describes what this build serves, which is worth reading whether
            // or not the listener happens to be running at this moment.
            HStack(spacing: 6) {
              Button {
                openWindow(id: APIDocsView.windowID)
              } label: {
                Label("View API Reference", systemImage: "curlybraces")
              }
              .buttonStyle(.link)

              Text("\(RouteCatalog.routes.count) endpoints")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
        }

        GlassCard {
          VStack(alignment: .leading, spacing: 10) {
            Text("Webhooks").font(.headline)

            if let manifest = webhooksManifest, !model.integrations.isEnabled(manifest) {
              FeatureDisabledNotice(
                manifest: manifest,
                model: model,
                consequence: "No events are being sent to your endpoints. "
                  + "Anything already registered is kept and starts "
                  + "receiving again as soon as this is turned back on."
              )
            } else {
              Text(
                "Endpoints the server POSTs events to. Each one chooses "
                  + "which events it receives."
              )
              .font(.caption).foregroundStyle(.secondary)

              HStack {
                Button("Add Webhook") { isAdding = true }
                Spacer()
              }

              if let message = screen.problem {
                ScreenErrorLine(message: message)
              }
            }

            // Listed either way. These rows are what someone came to check or to
            // remove, and hiding them behind the disabled state would mean
            // switching the feature on to get rid of an endpoint you no longer
            // want called.
            if webhooks.isEmpty, screen.state.isLoading {
              Text("Loading…").font(.caption).foregroundStyle(.secondary)
            } else if webhooks.isEmpty {
              Text("None registered.").font(.caption).foregroundStyle(.secondary)
            } else {
              // By URL, the identity the database enforces, so an insertion animates one
              // row rather than every row below it.
              ForEach(webhooks, id: \.url) { hook in
                if hook.url != webhooks.first?.url { Divider().padding(.vertical, 2) }
                row(hook)
              }
            }
          }
        }
      }
      .padding(20)
    }
  }

  private var webhooksEnabled: Bool {
    guard let webhooksManifest else { return true }
    return model.integrations.isEnabled(webhooksManifest)
  }

  private var webhooksManifest: ServiceManifest? {
    IntegrationCatalog.manifest(BuiltInManifests.ID.webhooks)
  }

  private var httpManifest: ServiceManifest? {
    IntegrationCatalog.manifest(BuiltInManifests.ID.http)
  }

  /// One registered endpoint: where it points, and what it is subscribed to.
  ///
  /// The subscription is on the row rather than behind the edit sheet because it is the
  /// thing you come here to check: "is this endpoint getting typing indicators?" should
  /// not need a click to answer.
  private func row(_ hook: Webhook) -> some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(hook.url)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        if let events = hook.decodedEvents {
          Text(WebhookEventCatalog.summary(for: events))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          // The stored event list could not be read, so this endpoint receives nothing.
          // Said here rather than rendered as "no events", which looks like a choice.
          Label(
            "Its event list could not be read, so nothing is delivered. Edit it to choose again.",
            systemImage: "exclamationmark.triangle"
          )
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
        }

        deliveryStatus(hook)
      }
      // One endpoint, not three fragments. The Test, Edit and Remove buttons are outside
      // this stack and stay reachable on their own.
      .accessibilityElement(children: .combine)

      Spacer(minLength: 8)

      Button(isTesting(hook) ? "Sending…" : "Test") { Task { await test(hook) } }
        .controlSize(.small)
        // Not offered while the sink is switched off. The test posts directly, so it
        // would succeed on a server that is delivering nothing: a green tick for a
        // feature that is off is worse than no button.
        .disabled(isTesting(hook) || !webhooksEnabled)
        .help(
          webhooksEnabled
            ? "Sends a hello-world event to this endpoint now, whatever it is "
              + "subscribed to."
            : "Webhooks are turned off, so nothing is being delivered.")
      Button("Edit") { editing = EditTarget(hook: hook) }
        .controlSize(.small)
      // Confirmed first: the URL and the event list are the person's own work. See the app
      // CLAUDE.md on destructive actions.
      Button("Remove", role: .destructive) { pendingRemoval = hook }
        .controlSize(.small)
        .disabled(screen.isPerforming)
    }
    .padding(.vertical, 2)
  }

  /// What happened the last time this server tried to reach the endpoint.
  ///
  /// The commonest webhook failure is a URL with a typo in it: it is accepted, listed, and
  /// never fires, and without this line the only signal is an alert on the tenth
  /// consecutive failure. Nothing at all is said when nothing has been attempted, rather
  /// than implying health either way.
  @ViewBuilder
  private func deliveryStatus(_ hook: Webhook) -> some View {
    if let state = delivery(for: hook) {
      let failed = state.outcome.isFailure
      HStack(spacing: 4) {
        // Decorative: the text beside it already says what happened, and a symbol with no
        // label is read as "image" and nothing more.
        Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
          .accessibilityHidden(true)
        Text(describe(state))
      }
      .font(.caption)
      .foregroundStyle(failed ? .orange : .secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// The tracked outcome for this row, if it belongs to it.
  ///
  /// Matched on the URL as well as the id: SQLite reuses row ids after a delete, and a
  /// previous endpoint's failure shown against a newly added one would be worse than
  /// showing nothing.
  private func delivery(for hook: Webhook) -> WebhookDeliveryState? {
    guard let id = hook.id, let state = deliveries[id], state.url == hook.url else {
      return nil
    }
    return state
  }

  private func describe(_ state: WebhookDeliveryState) -> String {
    let when = state.at.formatted(.relative(presentation: .numeric))
    switch state.outcome {
    case .delivered:
      return "Delivered \(when)"
    case .failed(let reason):
      // The streak is what separates "the endpoint blipped" from "this has been dead
      // all afternoon", and it is the same counter the alert fires on.
      let streak =
        state.consecutiveFailures > 1
        ? " · \(state.consecutiveFailures) in a row"
        : ""
      return "Failed \(when): \(reason)\(streak)"
    }
  }

  private func isTesting(_ hook: Webhook) -> Bool {
    guard let id = hook.id else { return false }
    return testing.contains(id)
  }

  private func test(_ hook: Webhook) async {
    guard let webhookAdmin = model.delivery.webhooks, let id = hook.id else { return }
    testing.insert(id)
    defer { testing.remove(id) }
    // Sending the test is not what fails visibly: the OUTCOME is the result, and it
    // lands in the same status line a real delivery writes to, so there is one place to
    // look rather than a transient toast the row then contradicts. No re-read: the
    // tracker publishes the outcome and the row reads it from the model.
    _ = await webhookAdmin.webhooks.sendTest(id: id)
  }

  private func remove(_ hook: Webhook) async {
    guard let serverAdmin = model.serverAdmin, let id = hook.id else { return }
    // Not `try?`: an endpoint that cannot be deleted must not leave the row on screen
    // with no explanation.
    await screen.perform { try await serverAdmin.deleteWebhook(id: id) }
  }
}
