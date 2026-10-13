//  ContactsView
//  The contact index, and a way to re-read the address book.
//
//  Paged, searched and sorted by the DATABASE. This page used to read the whole address book
//  and filter it in memory, which cost the memory of every contact for a table showing thirty
//  of them, and it read with a five-thousand ceiling that `ContactInterface.list` then clamped
//  to a thousand — so an address book larger than that was silently truncated, with the row
//  saying the list was capped naming a number that was never the cap.
//
//  Everything the page can do now goes to `ContactInterface.search`, which answers with a page
//  and the total matching it, from one read. That last part matters while contacts are being
//  removed — a Google account unlinked mid-visit — because a total from a second read
//  describes a table that no longer exists, and the page offers a page number that is gone.

import BBBuiltIns
import BBContacts
import BBInterfaces
import BBServiceKit
import BlueBubblesServerCore
import SwiftUI

/// What a change to means the page is read again: the integration being switched off, and
/// the query itself. One key, because it is the same read whichever of them moved.
private struct ReloadTrigger: Hashable {
  let disabled: Bool
  let query: String
}

struct ContactsView: View {

  @Bindable var model: AppModel
  @State private var screen: ScreenModel<ContactIndex.ContactPage>
  /// What to ask the database for. A reference type because `ScreenModel`'s read is a
  /// closure built once, in `init`, and it has to see the CURRENT query rather than the one
  /// that existed when the page was first shown.
  @State private var query = ContactsQuery()
  @State private var sortOrder = [KeyPathComparator(\ContactRowItem.name)]
  /// The outcome of the last re-index, which is a COUNT rather than a failure: "indexed
  /// 412, skipped 3". Kept apart from the model's error channel because it is the success
  /// message far more often than not.
  @State private var status: String?
  /// The Account labels the bulk control offers, with their counts.
  @State private var accountLabels: [(label: String, count: Int)] = []

  init(model: AppModel) {
    self.model = model
    let query = ContactsQuery()
    _query = State(initialValue: query)
    _screen = State(initialValue: ScreenModel { try await Self.read(model, query) })
  }

  @MainActor
  private static func read(
    _ model: AppModel, _ query: ContactsQuery
  ) async throws -> ContactIndex.ContactPage? {
    guard let interfaces = await model.messaging.interfaces() else { return nil }
    // Not `(try? …) ?? []`: a contact index that cannot be read must not look like an
    // address book with nobody in it, or the empty state tells the person to grant
    // Contacts access they may already have granted.
    return try await interfaces.contact.search(
      query: query.search.committed, order: query.order, ascending: query.ascending,
      limit: query.cursor.limit, offset: query.cursor.offset,
      // The one caller that asks for the switched-off ones: a switch you cannot see is a
      // switch you cannot undo.
      includeDisabled: true
    )
  }

  private var page: ContactIndex.ContactPage? { screen.state.value }
  /// The contacts on this page that are switched off.
  private var disabledIDs: Set<String> { page?.disabledIDs ?? [] }
  private var contacts: [ContactRecord] { page?.contacts ?? [] }
  /// How many contacts match the current search, which is not how many are on screen.
  private var total: Int { page?.total ?? 0 }

  /// The integration this page is a view of. Nil only if the manifest is missing, which
  /// would mean a build without the built-in list.
  private var manifest: ServiceManifest? {
    IntegrationCatalog.manifest(BuiltInManifests.ID.contacts)
  }

  private var isDisabled: Bool {
    guard let manifest else { return false }
    return !model.integrations.isEnabled(manifest)
  }

  /// The whole page while the integration is off, not a banner over the table: with it off
  /// the interface refuses every read, so there is no table to put a banner on. The notice
  /// carries the switch, so turning it back on is one click from where you noticed.
  private var feature: ListPageFeature? {
    manifest.map {
      ListPageFeature(
        manifest: $0,
        consequence: "Your address book is not being indexed and contacts are not "
          + "served to clients, so messages show phone numbers instead of names. "
          + "What was already indexed is kept and is served again as soon as this "
          + "is turned back on.")
    }
  }

  var body: some View {
    // Once per render. Building a row formats every phone number in it.
    let rows = contacts.map(ContactRowItem.init)
    return ListPage(
      model: model, screen: screen, symbol: "person.crop.circle", purpose: "view contacts",
      subject: "contacts", feature: feature, isEmpty: rows.isEmpty
    ) {
      emptyState
    } rows: {
      table(rows)
    } frame: { list in
      listCard(list)
    }
    .toolbar { toolbarItems }
    // Keyed on the integration as well as the server, and the second half is not optional:
    // toggling an integration does not change the phase, so without it the read that
    // FAILED while contacts were switched off stayed on screen after they were switched
    // back on: the refusal above the list, and "No contacts indexed" below it, describing
    // a read that never ran again.
    .reloads(
      screen, following: model, alsoOn: ReloadTrigger(disabled: isDisabled, query: query.reloadKey)
    )
    // The sort the table's own headers set, translated into the query so the DATABASE
    // answers in that order. A sort changes what "page 4" contains, so it goes back to the
    // first page for the reason `PageCursor.reset` gives.
    .onChange(of: sortOrder) { _, new in
      guard let comparator = new.first else { return }
      query.order = ContactsQuery.order(for: comparator)
      query.ascending = comparator.order == .forward
      query.cursor.reset()
    }
    // A new search redefines the pages, so it starts at the first one.
    .onChange(of: query.search.committed) { _, _ in query.cursor.reset() }
    .task(id: model.phase.isRunning) { await loadAccountLabels() }
  }

  /// The count and the re-index. Its own property for the reason `AuditLogView.toolbarItems`
  /// gives.
  @ViewBuilder
  private var toolbarItems: some View {
    // The count, where someone who just pressed Refresh is already looking. It is also
    // the quickest answer to "did the re-index work".
    if model.phase.isRunning, !isDisabled, !contacts.isEmpty {
      ToolbarCaption(countSummary)
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
        // Said here because the effect reaches further than this page, and a message showing
        // a bare phone number is easy to read as the index being broken rather than as a
        // switch somebody turned off.
        "Turning Served off keeps a contact out of everything this server sends: it is not "
          + "in the contact list, and messages from that person show their phone number "
          + "instead of their name. Editing your address book is unaffected.",
        "To change a contact that came from this Mac's address book, edit it in the "
          + "Contacts app and press Refresh.",
      ]
    )
  }

  /// Switching a whole account on or off at once.
  ///
  /// By the label the Account column SHOWS, which is the account name where there is one and
  /// the source otherwise, so the group this covers is the block the reader can see. Offered
  /// only once there is more than one label: with a single account it is a menu whose every
  /// item does the same thing as the one above it.
  @ViewBuilder
  private var bulkMenu: some View {
    if accountLabels.count > 1 {
      Menu {
        ForEach(accountLabels, id: \.label) { entry in
          Section(entry.label) {
            Button("Serve all \(entry.count.formatted(.number))") {
              Task { await setServed(true, accountLabel: entry.label) }
            }
            Button("Stop serving all \(entry.count.formatted(.number))") {
              Task { await setServed(false, accountLabel: entry.label) }
            }
          }
        }
      } label: {
        Label("Bulk change", systemImage: "line.3.horizontal.decrease.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .disabled(screen.isPerforming)
      .help("Serve or stop serving every contact from one account")
    }
  }

  /// Filtering, on the page rather than in the window toolbar; see `SearchField` for why it
  /// is not `.searchable`. Searched once typing pauses, because each search is a read of
  /// the index; see `SearchDraft`.
  ///
  /// Deliberately narrow and left-aligned: it filters the table under it, so it belongs at the
  /// table's leading edge rather than stretched across a column that is mostly names.
  private var searchField: some View {
    PausedSearchField("Search contacts", search: $query.search)
      .frame(maxWidth: 280, alignment: .leading)
  }

  /// The page: the explainer, the search and the bulk menu above the table, in the card
  /// every database-paged page uses.
  private func listCard<List: View>(_ list: List) -> some View {
    PagedTableCard(
      screen: screen, cursor: $query.cursor, showing: contacts.count, total: total,
      noun: "contact", status: status, list: list
    ) {
      explainer

      HStack(spacing: 10) {
        searchField
        Spacer()
        bulkMenu
      }
    }
  }

  /// What the card shows when the read succeeded and found nobody.
  ///
  /// Never while the read is running, and never over a read that failed: `ListPage` decides
  /// both. "No contacts indexed" tells someone to go and grant Contacts access, and shown
  /// over a read in flight or a refusal, it sends them to fix something that is not broken.
  private var emptyState: some View {
    // Keyed on the SEARCH rather than on whether rows are loaded. With the filter in the
    // database an empty page and an empty index look identical from here, and telling
    // someone to grant Contacts access because their search found nothing sends them to
    // fix a permission that is working.
    ContentUnavailableView(
      query.search.committed.isEmpty ? "No contacts indexed" : "No matches",
      systemImage: "person.crop.circle.badge.questionmark",
      description: Text(
        query.search.committed.isEmpty
          ? "Grant Contacts access, then refresh to index your address book."
          : "No contact matches “\(query.search.committed)”."
      )
    )
    // Fills, so it centres in the space under the header rather than sizing to its
    // content and dragging the header into the middle of the card with it. The table
    // needs no such frame: it already fills.
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// The rows, in the order the DATABASE returned them.
  ///
  /// No filtering and no sorting here: both are in the query, because a page is a window onto
  /// an ordered set and re-ordering the window shows the wrong rows. `Table`'s `sortOrder`
  /// binding still drives the column headers; it is translated into the query and the next
  /// read answers in that order.
  private func table(_ rows: [ContactRowItem]) -> some View {
    Table(rows, sortOrder: $sortOrder) {
      // Deliberately NOT sortable: the column holds a control rather than a value, and
      // `Table` would sort it by the row's name, which is the neighbouring column.
      TableColumn("Served") { row in
        Toggle(
          isOn: Binding(
            get: { !disabledIDs.contains(row.id) },
            set: { isOn in Task { await setServed(isOn, ids: [row.id]) } }
          )
        ) {
          // Named for the row it belongs to. Every one of these is a switch with the same
          // label otherwise, which to VoiceOver is a column of identical controls.
          Text("Serve \(row.name)")
        }
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
        .disabled(screen.isPerforming)
      }
      .width(60)

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
    // The table keeps its OWN opaque background, and that is the rule rather than a
    // preference: `GlassSurface` is for chrome, and "content surfaces stay opaque" is the
    // first thing its header says. Hidden, the glass showed through the whole table, which
    // on macOS 26 means `glassEffect` sampling the desktop behind the window — several
    // hundred points of wallpaper under the rows, which reads as a blue cast over the page
    // and costs the contrast the text needs. The card frames the table; it is not the
    // table's surface.
    .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.fieldCornerRadius))
  }

  /// "4,214 contacts", or how many match while a search is narrowing them.
  ///
  /// The count comes from the same read as the rows, so it counts what is in the INDEX and
  /// not what is on this page: a toolbar reading "100 contacts" on a Mac with four thousand
  /// is the old in-memory count wearing a new number.
  private var countSummary: String {
    guard query.search.committed.isEmpty else { return "\(total.formatted(.number)) matching" }
    return total.counted("contact")
  }

  /// Switches contacts on or off, then re-reads so the page shows what is stored.
  ///
  /// Re-read rather than adjusted in place: the write can fail, and a switch that has moved on
  /// screen while the database says otherwise is the worst of the three possible states.
  private func setServed(_ served: Bool, ids: [String]) async {
    let interfaces = await model.messaging.interfaces()
    status = nil
    await screen.perform(failureMessage: "Could not change which contacts are served.") {
      try await interfaces.orServerNotRunning().contact.setEnabled(served, ids: ids)
    }
    await screen.reload()
  }

  /// The bulk action, by the label the Account column shows.
  private func setServed(_ served: Bool, accountLabel: String) async {
    let interfaces = await model.messaging.interfaces()
    status = nil
    await screen.perform(failureMessage: "Could not change which contacts are served.") {
      let changed = try await interfaces.orServerNotRunning().contact.setEnabled(
        served, accountLabel: accountLabel)
      status =
        "\(changed.counted("contact")) from \(accountLabel) "
        + (served ? "will be served." : "will no longer be served.")
    }
    await screen.reload()
  }

  private func loadAccountLabels() async {
    guard let interfaces = await model.messaging.interfaces() else { return }
    // A glance rather than the page's content: a failure here costs the bulk menu its
    // options and nothing else, and the page reports its own read failures already.
    accountLabels = (try? await interfaces.contact.accountLabels()) ?? []
  }

  private func refresh() async {
    guard let interfaces = await model.messaging.interfaces() else {
      await screen.perform { throw ServerNotRunning() }
      return
    }
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
