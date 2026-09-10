//  ContactsView
//  The contact index, and a way to re-read the address book.

import BBBuiltIns
import BBContacts
import BBInterfaces
import BBServiceKit
import BlueBubblesServerCore
import SwiftUI

struct ContactsView: View {

  @Bindable var model: AppModel
  @State private var screen: ScreenModel<[ContactRecord]>
  @State private var search = ""
  @State private var sortOrder = [KeyPathComparator(\ContactRowItem.name)]
  /// The outcome of the last re-index, which is a COUNT rather than a failure: "indexed
  /// 412, skipped 3". Kept apart from the model's error channel because it is the success
  /// message far more often than not.
  @State private var status: String?

  /// How many rows this page asks for.
  ///
  /// A ceiling rather than paging, because the table filters in memory and paging would
  /// mean a search that could not see past the first page. Named so the row that says the
  /// list is capped cannot disagree with the read that capped it.
  private static let limit = 5000

  init(model: AppModel) {
    self.model = model
    _screen = State(initialValue: ScreenModel { try await Self.read(model) })
  }

  @MainActor
  private static func read(_ model: AppModel) async throws -> [ContactRecord]? {
    guard let interfaces = await model.messaging.interfaces() else { return nil }
    // Not `(try? …) ?? []`: a contact index that cannot be read must not look like an
    // address book with nobody in it, or the empty state tells the person to grant
    // Contacts access they may already have granted.
    return try await interfaces.contact.list(limit: Self.limit)
  }

  private var contacts: [ContactRecord] { screen.state.value ?? [] }

  /// The integration this page is a view of. Nil only if the manifest is missing, which
  /// would mean a build without the built-in list.
  private var manifest: ServiceManifest? {
    IntegrationCatalog.manifest(BuiltInManifests.ID.contacts)
  }

  private var isDisabled: Bool {
    guard let manifest else { return false }
    return !model.integrations.isEnabled(manifest)
  }

  var body: some View {
    Group {
      if !model.phase.isRunning {
        ServerStoppedNotice(
          model: model, placement: .page(symbol: "person.crop.circle"), purpose: "view contacts")
      } else if let manifest, isDisabled {
        // The whole page, not a banner over the table: with the integration off the
        // interface refuses every read, so there is no table to put a banner on. The notice
        // carries the switch, so turning it back on is one click from where you noticed.
        ScrollView {
          GlassCard {
            FeatureDisabledNotice(
              manifest: manifest,
              model: model,
              consequence: "Your address book is not being indexed and contacts are not "
                + "served to clients, so messages show phone numbers instead of names. "
                + "What was already indexed is kept and is served again as soon as this "
                + "is turned back on."
            )
          }
          .padding(20)
        }
      } else {
        // NO `.searchable`. The search field is a control on this page, drawn in `header`.
        //
        // Removed while hunting a bug it turned out not to cause, and kept because a field
        // on the page is the better answer anyway: it sits with the list it filters and
        // beside the count it changes, rather than in window chrome shared with navigation
        // that has nothing to do with contacts. Restoring `.searchable` would be an
        // untested change to a page that now works.
        list
      }
    }
    .toolbar {
      // The count, where someone who just pressed Refresh is already looking. It is also
      // the quickest answer to "did the re-index work".
      if model.phase.isRunning, !isDisabled, !contacts.isEmpty {
        Text(countSummary)
          .font(.callout)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Button {
        Task { await refresh() }
      } label: {
        Label("Refresh from Address Book", systemImage: "arrow.clockwise")
      }
      // Refusing rather than failing: with the integration off the interface throws, and a
      // button whose only outcome is an error is a button that should not be pressable.
      .disabled(screen.isPerforming || isDisabled)
    }
    // The switch lives on the Integrations screen AND on this page's own notice, so the
    // page has to reflect a change made either place, the same reason the webhooks page
    // refreshes.
    .task(id: model.phase.isRunning) { await model.integrations.refresh() }
    // Keyed on the integration as well as the server, and the second half is not optional:
    // toggling an integration does not change the phase, so without it the read that
    // FAILED while contacts were switched off stayed on screen after they were switched
    // back on: the refusal above the list, and "No contacts indexed" below it, describing
    // a read that never ran again.
    .reloads(screen, following: model, alsoOn: isDisabled)
  }

  /// WHAT THIS LIST IS FOR, and what it is not.
  ///
  /// Both halves are things somebody works out only by being surprised. Someone who sees a
  /// wrong name on their Android phone comes here to fix it, and nothing on the page said
  /// their phone never reads this. And every column here looks like a field, so the absence
  /// of an edit affordance reads as one that has not been found yet rather than one that
  /// does not exist.
  ///
  /// `NoticeBody` rather than `NoticeCard`, which is not a style choice: see `header`. It
  /// also happens to be what `GlassSurface` asks for, since glass is for chrome and this
  /// sits over a table of text somebody reads.
  private var explainer: some View {
    NoticeBody(
      symbol: "info.circle",
      title: "This list is read only",
      messages: [
        "These contacts are mainly used by the desktop app. The Android app reads contacts "
          + "from the phone it runs on, so nothing here changes what it shows.",
        "To change a contact that came from this Mac's address book, edit it in the "
          + "Contacts app and press Refresh.",
      ]
    )
  }

  /// Everything above the table, pinned, in the window's safe area.
  ///
  /// `.safeAreaInset` AND NOT A `VStack`, and the difference is the whole of a bug rather
  /// than a preference. The detail column of a `NavigationSplitView` extends UNDER the
  /// window's title bar, and a `Table` placed as that column's root view insets itself for
  /// it. Put anything above the table in a `VStack` and the table is no longer the root:
  /// the inset is not applied, and the first rows are drawn behind the header where nobody
  /// can read or click them.
  ///
  /// It never showed while everything above the table was CONDITIONAL: an error line, a
  /// status line, a ceiling note. On an ordinary visit none of them was there and
  /// the table was the first child after all. Adding a permanent card at the top made the
  /// bad case the only case.
  ///
  /// `safeAreaInset` is the tool for exactly this: the accessory is placed in the safe
  /// area, the scrollable content keeps its own inset behaviour, and the space is reserved
  /// rather than overlaid. An opaque background, because rows scroll UNDER an accessory and
  /// would otherwise be legible through it.
  private var header: some View {
    VStack(alignment: .leading, spacing: 0) {
      explainer
        .padding(.horizontal, 12)
        .padding(.vertical, 10)

      searchField
        .padding(.horizontal, 12)
        .padding(.bottom, 10)

      if let message = screen.problem {
        ScreenErrorLine(message: message).padding(8)
      } else if let status {
        Text(status).font(.caption).foregroundStyle(.secondary).padding(8)
      }
      // Said rather than left to be discovered: past the ceiling, a search for someone in
      // the tail reports "No matches", which reads as an address book that does not have
      // them rather than a list that stopped early.
      if contacts.count >= Self.limit {
        SettingsFootnote(
          text: "Showing the first \(Self.limit.counted("contact")). "
            + "The index holds more; search finds only what is listed here.",
          kind: .status,
          symbol: "info.circle"
        )
        .padding(8)
      }

      Divider()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.bar)
  }

  /// Filtering, on the page rather than in the window toolbar.
  ///
  /// Hand-built rather than `.searchable`, which was removed while hunting a bug it turned
  /// out not to cause. The reasoning is on the branch that no longer applies it.
  ///
  /// Deliberately narrow and left-aligned: it
  /// filters the table under it, so it belongs at the table's leading edge rather than
  /// stretched across a column that is mostly names.
  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        // The field beside it is named, so this would be read out twice.
        .accessibilityHidden(true)

      TextField("Search contacts", text: $search)
        .textFieldStyle(.plain)

      // Only once there is something to clear. A permanently visible clear button on an
      // empty field invites a click that does nothing.
      if !search.isEmpty {
        Button {
          search = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    .frame(maxWidth: 280, alignment: .leading)
  }

  private var list: some View {
    // Once per render. Building a row formats every phone number in it, and this was being
    // rebuilt on each of the two places it is read.
    let rows = visible
    return content(rows)
      .safeAreaInset(edge: .top, spacing: 0) { header }
  }

  @ViewBuilder
  private func content(_ rows: [ContactRowItem]) -> some View {
    if rows.isEmpty, screen.state.isLoading {
      // "No contacts indexed" tells someone to go and grant Contacts access. Shown
      // while the read is still running, it sends them to fix something that is not
      // broken.
      LoadingNotice(subject: "contacts")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if rows.isEmpty {
      ContentUnavailableView(
        contacts.isEmpty ? "No contacts indexed" : "No matches",
        systemImage: "person.crop.circle.badge.questionmark",
        description: Text(
          contacts.isEmpty
            ? "Grant Contacts access, then refresh to index your address book."
            : "No contact matches “\(search)”."
        )
      )
      // Fills so it centres in the space UNDER the header, rather than sizing to its
      // content and dragging the header into the middle of the page with it. NOT applied
      // to the table below: a table already fills, and a fill frame wrapping it sat in
      // front of the inset and made the header invisible as soon as there were rows.
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      Table(rows, sortOrder: $sortOrder) {
        TableColumn("Name", value: \.name)
        TableColumn("Phone", value: \.phones) { Text($0.phones).monospacedDigit() }
        TableColumn("Email", value: \.emails)
        // The ACCOUNT, not the storage origin. "api"/"db" is what the wire format
        // has always called address-book vs server-created, and it answers a
        // question nobody was asking while hiding the one they were.
        //
        // Sorted on `accountLabel`, which is what the column actually shows: sorting on
        // the optional would file every unlabelled row together regardless of the
        // fallback the person can see.
        TableColumn("Account", value: \.accountLabel) { row in
          if let account = row.account {
            Text(account)
          } else {
            Text(row.source).foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  /// The rows the table shows: filtered, then sorted the way the header was clicked.
  private var visible: [ContactRowItem] {
    let rows = contacts.map(ContactRowItem.init)
    let matching =
      search.isEmpty
      ? rows
      : rows.filter { $0.searchText.localizedCaseInsensitiveContains(search) }
    return matching.sorted(using: sortOrder)
  }

  /// "412 contacts", or "12 of 412" while a search is narrowing them.
  private var countSummary: String {
    let total = contacts.count
    guard !search.isEmpty else { return total.counted("contact") }
    return "\(visible.count) of \(total.formatted(.number))"
  }

  private func refresh() async {
    guard let interfaces = await model.messaging.interfaces() else { return }
    status = nil
    // The likely cause, named. "Operation failed" would send someone hunting.
    await screen.perform(
      failureMessage: "Could not read the address book, check Contacts permission."
    ) {
      let result = try await interfaces.contact.refresh()
      status = "Indexed \(result.indexed), skipped \(result.skipped)."
    }
  }
}

/// A flattened row.
///
/// `ContactRecord` is `Identifiable`, so this exists purely to turn a record into the four
/// strings the table shows.
struct ContactRowItem: Identifiable {
  let record: ContactRecord
  var id: String { record.id }

  init(_ record: ContactRecord) { self.record = record }

  var name: String {
    record.displayName
      ?? [record.firstName, record.lastName]
      .compactMap { $0 }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
  }

  var phones: String { AddressFormatting.list(record.phoneNumbers, areEmails: false) }
  var emails: String { AddressFormatting.list(record.emailAddresses, areEmails: true) }
  /// The account label, once the contact has been re-indexed since accounts were recorded.
  ///
  /// Read from the record rather than from a serialized dictionary: an absent key is
  /// silent, an absent property does not compile.
  var account: String? { record.account?.label }
  /// Shown only as a fallback, for rows indexed before accounts were recorded.
  var source: String {
    switch record.source {
    case .macOS: "Address Book"
    case .local: "Local"
    }
  }
  /// What the Account column shows, and what sorting it orders by.
  var accountLabel: String { account ?? source }
  // Searches the RAW addresses as well as the formatted ones, so typing a bare "5550101234"
  // still finds a number displayed as "(555) 010-1234".
  var searchText: String {
    ([name, phones, emails] + record.phoneNumbers + record.emailAddresses)
      .joined(separator: " ")
  }
}
