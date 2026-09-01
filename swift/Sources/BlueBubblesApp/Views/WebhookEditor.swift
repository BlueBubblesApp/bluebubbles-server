//  WebhookEditor
//  Registering an endpoint, and choosing what gets sent to it.
//
//  The page it replaces had a URL field and an Add button, and every endpoint it created was
//  subscribed to `["*"]`. That is a real loss of function rather than a cosmetic one: an
//  endpoint that wanted `new-message` was also being handed every typing indicator, every
//  FindMy location update and every backup event, and the only way to narrow it was to
//  register the webhook over the REST API instead of in the app that exists to manage it.
//
//  The same sheet edits an existing webhook. Editing is why the server grew `webhook.update`:
//  `createWebhook` upserts on the URL, so "save" on a changed address through that path would
//  have left the old address registered and still being POSTed to.
//
//  That upsert is also why this sheet knows about the OTHER webhooks. Adding a URL that is
//  already registered is not an error at the database — it silently rewrites that row's
//  subscription, so someone re-adding an endpoint they already had would quietly replace its
//  events and see a list that had not grown. The Electron UI refused it outright; this offers
//  the thing the person probably meant instead.
//
//  See `.claude/docs/architecture.md`.

import BBHandlers
import BBInterfaces
import BlueBubblesServerCore
import SwiftUI

struct WebhookEditor: View {

  @Bindable var model: AppModel
  /// The webhook to open on, or nil to register a new one.
  var initial: Webhook?
  /// Every registered webhook, for the duplicate check. Passed in rather than re-fetched:
  /// the list is already loaded on the page that presents this sheet.
  var existing: [Webhook] = []
  let onDone: () -> Void

  @Environment(\.dismiss) private var dismiss

  @State private var url = ""
  @State private var subscription = EventSubscription()
  @State private var isSaving = false
  @State private var error: String?
  /// The webhook being edited. Seeded from `initial`, and changed by "Edit That One" when
  /// the URL turns out to be one already registered.
  @State private var target: Webhook?
  @State private var hasLoaded = false

  private var isEditing: Bool { target != nil }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
          endpointSection
          eventsSection
        }
        .padding(SettingsMetrics.pagePadding)
      }
      Divider()
      footer
    }
    .frame(width: 620, height: 660)
    .onAppear(perform: loadInitial)
  }

  // MARK: - Chrome

  private var header: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(isEditing ? "Edit Webhook" : "Add a Webhook")
        .font(.title3.weight(.semibold))
      Text(
        "The server POSTs a JSON body of `{\"type\": …, \"data\": …}` to this URL "
          + "when a subscribed event happens."
      )
      .font(.callout).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(20)
  }

  private var footer: some View {
    HStack(spacing: 12) {
      if let error {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.callout).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button(isEditing ? "Save" : "Add") { Task { await save() } }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(!canSave || isSaving)
    }
    .padding(16)
  }

  // MARK: - Sections

  private var endpointSection: some View {
    SettingsSection("Endpoint") {
      SettingsWideRow(
        title: "URL",
        help: "An http or https URL this server can reach."
      ) {
        TextField("https://example.com/hook", text: $url)
          .textFieldStyle(.roundedBorder)
          .controlSize(.large)
      }

      // The duplicate is caught HERE rather than at save time, because the useful
      // response is not "no" — it is the row they already have, with a way into it.
      if let conflict {
        SettingsDivider()
        VStack(alignment: .leading, spacing: 8) {
          SettingsFootnote(
            text: "This URL is already registered, receiving "
              + "\(EventSubscription(wireValues: conflict.subscribedEvents).summary.lowercased())"
              + ". Adding it again would replace those subscriptions.",
            symbol: "exclamationmark.triangle",
            tone: .warning
          )
          Button("Edit That One Instead") { adopt(conflict) }
            .buttonStyle(.link)
        }
        .padding(.vertical, 4)
      }
    }
  }

  private var eventsSection: some View {
    SettingsSection(
      "Event Subscriptions",
      subtitle: "Which events this endpoint receives. Everything else is not sent to it "
        + "at all.",
      trailing: AnyView(
        Text(subscription.isAllEvents ? "All" : "\(subscription.selected.count) selected")
          .font(.callout).foregroundStyle(.tertiary)
      )
    ) {
      EventSubscriptionPicker(
        subscription: $subscription,
        emptyWarning: "Pick at least one event, or switch back to All events. An "
          + "endpoint subscribed to nothing is never called."
      )
    }
  }

  // MARK: - Duplicates

  /// A different webhook already registered for the URL being typed.
  private var conflict: Webhook? {
    let address = url.trimmingCharacters(in: .whitespaces).lowercased()
    guard !address.isEmpty else { return nil }
    let editingID = target?.id
    return existing.first { $0.url.lowercased() == address && $0.id != editingID }
  }

  /// Switches the sheet onto the webhook that already holds this URL.
  private func adopt(_ hook: Webhook) {
    target = hook
    url = hook.url
    subscription = EventSubscription(wireValues: hook.subscribedEvents)
    error = nil
  }

  // MARK: - Loading and saving

  private var canSave: Bool {
    guard !url.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
    // A duplicate blocks the save rather than warning and proceeding. The upsert behind
    // it is silent and lossy, so there is nothing useful on the other side of "save
    // anyway" that "Edit That One Instead" does not do better.
    return subscription.isValid && conflict == nil
  }

  private func loadInitial() {
    // `onAppear` can run more than once for one presentation; re-seeding would throw away
    // whatever had been typed.
    guard !hasLoaded else { return }
    hasLoaded = true
    guard let initial else { return }
    target = initial
    url = initial.url
    subscription = EventSubscription(wireValues: initial.subscribedEvents)
  }

  private func save() async {
    guard let serverAdmin = model.serverAdmin else {
      error = "The server is not running."
      return
    }

    isSaving = true
    defer { isSaving = false }

    let address = url.trimmingCharacters(in: .whitespaces)
    let events = subscription.wireValues

    do {
      if let id = target?.id {
        _ = try await serverAdmin.updateWebhook(id: id, url: address, events: events)
      } else {
        _ = try await serverAdmin.createWebhook(url: address, events: events)
      }
      onDone()
      dismiss()
    } catch {
      self.error = String(describing: error)
    }
  }
}
