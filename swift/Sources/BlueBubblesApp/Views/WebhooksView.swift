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

  /// The page's three reads as one value.
  ///
  /// A snapshot rather than three `@State` properties because they are read together and
  /// are only meaningful together: the address card describes the listener the endpoints
  /// below it are registered against. Read separately, a failure partway through left a
  /// fresh list beside a stale address with nothing saying which was which.
  struct Registrations: Sendable {
    var webhooks: [Webhook] = []
    /// What each endpoint's last delivery did, keyed by webhook id. Empty until something
    /// has been delivered — it describes what this run of the server has seen.
    var deliveries: [Int64: WebhookDeliveryState] = [:]
    var address = "—"
  }

  init(model: AppModel) {
    self.model = model
    _screen = State(initialValue: ScreenModel { try await Self.read(model) })
  }

  /// Nil until the server is running, which is what keeps "not started yet" out of the
  /// error path — see `ScreenModel.read`.
  @MainActor
  private static func read(_ model: AppModel) async throws -> Registrations? {
    guard let serverAdmin = model.serverAdmin, let settings = model.settings else {
      return nil
    }
    let port = await settings.get(Settings.socketPort)
    let configured = await settings.get(Settings.serverAddress)
    return Registrations(
      // No longer `(try? …) ?? []`. A list the server refused to produce and a server
      // with no endpoints registered were arriving here as the same empty array.
      webhooks: try await serverAdmin.webhooks(),
      deliveries: await model.webhookAdmin?.webhooks.deliveries.all() ?? [:],
      address: configured.isEmpty ? "http://localhost:\(port)" : configured
    )
  }

  private var webhooks: [Webhook] { screen.state.value?.webhooks ?? [] }
  private var deliveries: [Int64: WebhookDeliveryState] { screen.state.value?.deliveries ?? [:] }
  private var address: String { screen.state.value?.address ?? "—" }

  /// `.sheet(item:)` needs an `Identifiable`, and `Webhook` is a database record whose
  /// `id` is optional until it is stored. This pins the one being edited, which always has
  /// one.
  private struct EditTarget: Identifiable {
    let hook: Webhook
    var id: Int64 { hook.id ?? 0 }
  }

  var body: some View {
    Group {
      if !model.phase.isRunning {
        ContentUnavailableView(
          "Server not running",
          systemImage: "network",
          description: Text("Start the server to manage webhooks.")
        )
      } else {
        content
      }
    }
    .task {
      // Re-read on appear: the switch lives on another screen, and a page that decides
      // whether a feature is on when the app launched would show a stale answer for the
      // rest of the session.
      await model.integrations.refresh()
      await screen.reload()
    }
    // Delivery outcomes change without anything on this page doing anything — an event
    // fires, an endpoint starts failing. A page that answered "is this working" only as
    // of the moment it opened would be answering a different question.
    //
    // This re-reads the whole snapshot rather than the delivery table alone, which it used
    // to. Two reasons it is worth the extra list read: an endpoint registered from another
    // client now appears without reopening the page, and a delivery table that has started
    // FAILING to read now says so instead of showing the last good answer indefinitely.
    .task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(10))
        if Task.isCancelled { return }
        await screen.reload()
      }
    }
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
              HStack {
                Text(address)
                  .font(.system(.body, design: .monospaced))
                  .textSelection(.enabled)
                Button {
                  NSPasteboard.general.clearContents()
                  NSPasteboard.general.setString(address, forType: .string)
                } label: {
                  Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .disabled(address == "—")
              }
              Text("This is what clients connect to.")
                .font(.caption).foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 2)

            // The reference belongs on this page and not in the sidebar: someone who has
            // just copied the address is, right then, about to go and look up what to
            // send to it. It sits OUTSIDE the disabled branch above on purpose — the
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
            if webhooks.isEmpty {
              Text("None registered.").font(.caption).foregroundStyle(.secondary)
            } else {
              ForEach(webhooks.indices, id: \.self) { index in
                if index > 0 { Divider().padding(.vertical, 2) }
                row(webhooks[index])
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
  /// thing you come here to check — "is this endpoint getting typing indicators?" should
  /// not need a click to answer.
  private func row(_ hook: Webhook) -> some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(hook.url)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        Text(WebhookEventCatalog.summary(for: hook.subscribedEvents))
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        deliveryStatus(hook)
      }

      Spacer(minLength: 8)

      Button(isTesting(hook) ? "Sending…" : "Test") { Task { await test(hook) } }
        .controlSize(.small)
        // Not offered while the sink is switched off. The test posts directly, so it
        // would succeed on a server that is delivering nothing — a green tick for a
        // feature that is off is worse than no button.
        .disabled(isTesting(hook) || !webhooksEnabled)
        .help(
          webhooksEnabled
            ? "Sends a hello-world event to this endpoint now, whatever it is "
              + "subscribed to."
            : "Webhooks are turned off, so nothing is being delivered.")
      Button("Edit") { editing = EditTarget(hook: hook) }
        .controlSize(.small)
      Button("Remove", role: .destructive) { Task { await remove(hook) } }
        .controlSize(.small)
    }
    .padding(.vertical, 2)
  }

  /// What happened the last time this server tried to reach the endpoint.
  ///
  /// The commonest webhook failure is a URL with a typo in it: it is accepted, listed, and
  /// never fires, and until this line existed the only signal was an alert on the tenth
  /// consecutive failure. Nothing at all is said when nothing has been attempted, rather
  /// than implying health either way.
  @ViewBuilder
  private func deliveryStatus(_ hook: Webhook) -> some View {
    if let state = delivery(for: hook) {
      let failed = state.outcome.isFailure
      HStack(spacing: 4) {
        Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
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
      return "Failed \(when) — \(reason)\(streak)"
    }
  }

  private func isTesting(_ hook: Webhook) -> Bool {
    guard let id = hook.id else { return false }
    return testing.contains(id)
  }

  private func test(_ hook: Webhook) async {
    guard let webhookAdmin = model.webhookAdmin, let id = hook.id else { return }
    testing.insert(id)
    defer { testing.remove(id) }
    // Sending the test is not what fails visibly — the OUTCOME is the result, and it
    // lands in the same status line a real delivery writes to, so there is one place to
    // look rather than a transient toast the row then contradicts.
    _ = await webhookAdmin.webhooks.sendTest(id: id)
    await screen.reload()
  }

  private func remove(_ hook: Webhook) async {
    guard let serverAdmin = model.serverAdmin, let id = hook.id else { return }
    // Was `try?`, so an endpoint that could not be deleted left the row on screen with
    // no explanation and no error anywhere.
    await screen.perform { try await serverAdmin.deleteWebhook(id: id) }
  }
}
