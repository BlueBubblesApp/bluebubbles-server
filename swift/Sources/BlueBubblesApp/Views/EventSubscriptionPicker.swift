//  EventSubscriptionPicker
//  Choosing which events a delivery target receives.
//
//  Shared between the webhook editor and the ntfy settings row, because the two had the same
//  gap for the same reason: both sinks have supported a per-target event list all along
//  (`WebhookTarget.matches`, `NtfyTarget.matches`), and both were being constructed with the
//  wildcard because no screen ever asked. One picker means fixing it once, and means the two
//  cannot drift into offering different vocabularies for the same events.
//
//  See `.claude/docs/architecture.md`.

import SwiftUI

struct EventSubscriptionPicker: View {

  @Binding var subscription: EventSubscription

  /// What is not being delivered while the selection is empty. Different per target — a
  /// webhook is not called, an ntfy topic gets nothing posted to it.
  var emptyWarning: String

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SettingsRow(title: "Send") {
        Picker(
          "",
          selection: Binding(
            get: { subscription.isAllEvents },
            set: { subscription.isAllEvents = $0 }
          )
        ) {
          Text("All events").tag(true)
          Text("Only selected").tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }

      if subscription.isAllEvents {
        SettingsDivider()
        // Stated where it is chosen: this is the whole difference between the
        // wildcard and ticking every box, and it is invisible otherwise.
        SettingsFootnote(
          text: "Includes any event added in a future server version.",
          symbol: "info.circle"
        )
        .padding(.vertical, 4)
      } else {
        SettingsDivider()

        HStack(spacing: 12) {
          Button("Select All") {
            subscription.selected = Set(WebhookEventCatalog.all.map(\.value))
          }
          Button("Select None") { subscription.selected.removeAll() }
          Spacer()
        }
        .buttonStyle(.link)
        .padding(.vertical, 4)

        ForEach(WebhookEventCatalog.groups) { group in
          SettingsDivider()
          SettingsWideRow(title: group.title) {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(group.events) { event in
                Toggle(event.label, isOn: binding(for: event.value))
                  .toggleStyle(.checkbox)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }

        // Anything stored that this picker has no checkbox for — an event name a
        // client registered over the API, or one from a newer server. Shown rather
        // than dropped, and removable, because otherwise it is a subscription nothing
        // in the app can see or undo.
        if !unrecognised.isEmpty {
          SettingsDivider()
          SettingsWideRow(
            title: "Other",
            help: "Not offered here — registered by a client, or from a newer "
              + "server version. Kept as-is unless you clear it."
          ) {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(unrecognised, id: \.self) { value in
                Toggle(value, isOn: binding(for: value))
                  .toggleStyle(.checkbox)
                  .font(.system(.body, design: .monospaced))
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }

        if subscription.selected.isEmpty {
          SettingsDivider()
          SettingsFootnote(
            text: emptyWarning, symbol: "exclamationmark.triangle",
            tone: .warning
          )
          .padding(.vertical, 4)
        }
      }
    }
  }

  private var unrecognised: [String] {
    let known = Set(WebhookEventCatalog.all.map(\.value))
    return subscription.selected.subtracting(known).sorted()
  }

  private func binding(for value: String) -> Binding<Bool> {
    Binding(
      get: { subscription.selected.contains(value) },
      set: { isOn in
        if isOn {
          subscription.selected.insert(value)
        } else {
          subscription.selected.remove(value)
        }
      }
    )
  }
}
