//  WebhookEditor
//  Registering an endpoint, and choosing what gets sent to it.
//
//  A URL field alone would subscribe every endpoint to `["*"]`, which is a real loss of
//  function: an endpoint that wants `new-message` is also handed every typing indicator,
//  every FindMy location update and every backup event.
//
//  The same sheet edits an existing webhook, through `webhook.update`: `createWebhook`
//  upserts on the URL, so "save" on a changed address through that path would leave the old
//  address registered and still being POSTed to.
//
//  That upsert is also why this sheet knows about the OTHER webhooks. Adding a URL that is
//  already registered is not an error at the database; it silently rewrites that row's
//  subscription, so someone re-adding an endpoint they already had would quietly replace its
//  events and see a list that had not grown. The Electron UI refused it outright; this offers
//  the thing the person probably meant instead.
//
//  The conversations section appears only while the chosen events include one about a
//  conversation (`EventSubscription.includesChatEvents`): a chat filter on an endpoint that
//  receives server updates and backups would narrow nothing, and asking for one would suggest
//  it did. When it is hidden the webhook is saved as taking every conversation, so what is
//  stored is what the sheet showed.
//
//  Retries open on `Webhook.defaultRetryPolicy` for a new endpoint, and on the stored policy
//  for an existing one. The schedule is spelt out under the controls (`WebhookRetryChoice`)
//  because "first retry after 30 seconds, doubling" is arithmetic nobody should have to do to
//  find out how long an event is held.
//
//  See `.claude/docs/architecture.md`.

import BBAppStore
import BBCore
import BBEvents
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
  @State private var chats = WebhookChatSelection()
  @State private var retry = WebhookRetryChoice(policy: Webhook.defaultRetryPolicy)
  @State private var isSaving = false
  @State private var error: String?
  /// The webhook being edited. Seeded from `initial`, and changed by "Edit That One" when
  /// the URL turns out to be one already registered.
  @State private var target: Webhook?
  @State private var hasLoaded = false
  /// Off for a new endpoint, and whatever the row says for an existing one. See
  /// `WebhookTarget.followRedirects`.
  @State private var followRedirects = Webhook.defaultFollowRedirects

  private var isEditing: Bool { target != nil }

  var body: some View {
    SheetScaffold(
      title: isEditing ? "Edit Webhook" : "Add a Webhook",
      subtitle: "The server POSTs a JSON body of `{\"type\": …, \"data\": …}` to this URL "
        + "when a subscribed event happens.",
      confirmTitle: isEditing ? "Save" : "Add",
      isConfirmEnabled: canSave && !isSaving,
      error: error,
      confirm: { await save() }
    ) {
      endpointSection
      eventsSection
      if subscription.includesChatEvents {
        chatsSection
      }
      retrySection
    }
    .onAppear(perform: loadInitial)
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

      SettingsDivider()

      SettingsRow(
        title: "Follow Redirects",
        help: "Off means a 3xx from this endpoint is reported as a failed delivery instead "
          + "of being followed. Leave it off unless your endpoint is behind something that "
          + "redirects: a redirect can send your message content somewhere you did not "
          + "register.",
        footnotes: followRedirects
          ? [
            SettingsFootnote(
              text: "Whatever this endpoint redirects to will receive your messages, "
                + "including addresses on this Mac's own network.",
              symbol: "exclamationmark.triangle",
              tone: .warning
            )
          ] : []
      ) {
        Toggle("", isOn: $followRedirects)
          .labelsHidden()
          .toggleStyle(.switch)
      }

      // The duplicate is caught HERE rather than at save time, because the useful
      // response is not "no"; it is the row they already have, with a way into it.
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
        + "at all."
    ) {
      EventSubscriptionPicker(
        subscription: $subscription,
        emptyWarning: "Pick at least one event, or switch back to All events. An "
          + "endpoint subscribed to nothing is never called."
      )
    } trailing: {
      Text(subscription.isAllEvents ? "All" : "\(subscription.selected.count) selected")
        .font(.callout).foregroundStyle(.tertiary)
    }
  }

  private var chatsSection: some View {
    SettingsSection(
      "Conversations",
      subtitle: "Which conversations this endpoint is sent message, typing, read and group "
        + "events for. Events that are not about a conversation are sent either way."
    ) {
      WebhookChatPicker(model: model, selection: $chats)
    } trailing: {
      Text(chats.isAllChats ? "All" : "\(chats.selected.count) selected")
        .font(.callout).foregroundStyle(.tertiary)
    }
  }

  private var retrySection: some View {
    SettingsSection(
      "Retries",
      subtitle: "What happens when this endpoint cannot be reached, or answers with an error."
    ) {
      SettingsRow(
        title: "Retry Failed Deliveries",
        help: "Timeouts, connection failures, HTTP 408, 425 and 429, and any 5xx response are "
          + "retried. Any other response means the request itself was refused, and sending it "
          + "again would be refused the same way."
      ) {
        Toggle("", isOn: $retry.isEnabled)
          .labelsHidden()
          .toggleStyle(.switch)
      }

      SettingsDivider()

      if retry.isEnabled {
        SettingsRow(
          title: "Retries",
          help: "How many more times one event is tried after its first attempt fails."
        ) {
          Stepper(
            retry.retries.counted("retry", "retries"),
            value: $retry.retries,
            in: WebhookRetryChoice.retryRange
          )
        }

        SettingsDivider()

        SettingsRow(
          title: "First Retry After",
          help: "Each later retry waits twice as long as the one before, up to an hour."
        ) {
          Picker("", selection: $retry.initialDelaySeconds) {
            ForEach(retry.delayOptions, id: \.self) { seconds in
              Text(WebhookRetryChoice.label(seconds: seconds)).tag(seconds)
            }
          }
          .labelsHidden()
          .controlSize(.large)
          .frame(maxWidth: 200)
        }

        SettingsDivider()

        VStack(alignment: .leading, spacing: 6) {
          SettingsFootnote(text: retry.schedule, symbol: "clock.arrow.circlepath")
          SettingsFootnote(
            text: "While this endpoint is failing, newer events wait behind the failed one, "
              + "so they arrive in order once it recovers. Typing indicators are not held.",
            symbol: "list.number"
          )
          SettingsFootnote(
            text: "Every attempt carries an X-BlueBubbles-Delivery-Id header, the same on each "
              + "retry of one event, and an X-BlueBubbles-Delivery-Attempt header counting from "
              + "1. Use the ID to ignore an event you have already handled.",
            symbol: "info.circle"
          )
        }
        .padding(.vertical, 4)
      } else {
        SettingsFootnote(text: retry.schedule, symbol: "info.circle")
          .padding(.vertical, 4)
      }
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
    chats = WebhookChatSelection(scope: hook.chatScope)
    retry = WebhookRetryChoice(policy: hook.retryPolicy)
    followRedirects = hook.followRedirects
    error = nil
  }

  // MARK: - Loading and saving

  private var canSave: Bool {
    guard !url.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
    // A duplicate blocks the save rather than warning and proceeding. The upsert behind
    // it is silent and lossy, so there is nothing useful on the other side of "save
    // anyway" that "Edit That One Instead" does not do better.
    return subscription.isValid && conflict == nil
      && (!subscription.includesChatEvents || chats.isValid)
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
    chats = WebhookChatSelection(scope: initial.chatScope)
    retry = WebhookRetryChoice(policy: initial.retryPolicy)
    followRedirects = initial.followRedirects
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
    // Every conversation when the section is not showing; see the file header.
    let chatScope = subscription.includesChatEvents ? chats.scope : .allChats

    do {
      // Passed on BOTH paths, and never left to default. The interface reads nil as "no
      // opinion" so a client that has never heard of the switch cannot disarm it by
      // omission; this sheet always has an opinion, because the switch is on screen. The
      // chat filter and the retry policy follow the same rule.
      if let id = target?.id {
        _ = try await serverAdmin.updateWebhook(
          id: id, url: address, events: events, followRedirects: followRedirects,
          chatScope: chatScope, retryPolicy: retry.policy
        )
      } else {
        _ = try await serverAdmin.createWebhook(
          url: address, events: events, followRedirects: followRedirects,
          chatScope: chatScope, retryPolicy: retry.policy
        )
      }
      onDone()
      dismiss()
    } catch {
      self.error = DiagnosticText.sentence(for: error)
    }
  }
}
