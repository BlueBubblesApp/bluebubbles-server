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

  /// How many contacts one page holds.
  ///
  /// Not a ceiling: everything past it is one click away, and search looks at the whole
  /// index rather than at what is loaded. A hundred fills a tall window without the read
  /// growing with the address book, which is the property the old five-thousand read did
  /// not have.
  static let pageSize = 100

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
      query: query.search, order: query.order, ascending: query.ascending,
      limit: pageSize, offset: query.offset,
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
    .reloads(
      screen, following: model, alsoOn: ReloadTrigger(disabled: isDisabled, query: query.reloadKey)
    )
    // The sort the table's own headers set, translated into the query so the DATABASE
    // answers in that order. A sort changes what "page 4" contains, so it goes back to the
    // first page for the reason `resetPaging` gives.
    .onChange(of: sortOrder) { _, new in
      guard let comparator = new.first else { return }
      query.order = ContactsQuery.order(for: comparator)
      query.ascending = comparator.order == .forward
      query.resetPaging()
    }
    // A new search redefines the pages, so it starts at the first one.
    .onChange(of: query.search) { _, _ in query.resetPaging() }
    // Contacts can disappear while this page is open — a Google account unlinked, a group
    // deleted, a re-index that finds fewer. The page the person is on may no longer exist,
    // and an offset past the end answers with no rows: an empty table that reads as a failed
    // read. Pull it back into range, and read again only if it actually moved.
    .task(id: model.phase.isRunning) { await loadAccountLabels() }
    .onChange(of: total) { _, newTotal in
      if query.clamp(toTotal: newTotal, pageSize: Self.pageSize) {
        Task { await screen.reload() }
      }
    }
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

      TextField("Search contacts", text: $query.search)
        .textFieldStyle(.plain)

      // Only once there is something to clear. A permanently visible clear button on an
      // empty field invites a click that does nothing.
      if !query.search.isEmpty {
        Button {
          query.search = ""
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

  /// The page: one centred glass card holding the header, the table and the pager.
  ///
  /// **A card rather than a bare table, and this became possible only once the table was
  /// PAGED.** `TablePage` rather than `SettingsPage` because the latter is a `ScrollView`, and
  /// a `Table` inside one has unbounded height: it loses its own scrolling and the row
  /// recycling that comes with it. Same centred column either way; the card fills the page and
  /// the table fills the card, keeping the table the thing that scrolls.
  ///
  /// The header is stacked here rather than floated with `.safeAreaInset`. That inset existed
  /// because a `Table` placed as the root of a `NavigationSplitView` detail column insets
  /// itself for the title bar, and anything above it in a `VStack` took that away — the first
  /// rows drew behind the header. The card's own padding plus the page padding now puts about
  /// fifty points of chrome above the first row, which is the space that inset was reserving.
  /// If a row ever hides under the title bar again, THIS is the paragraph that was wrong.
  private var list: some View {
    // Once per render. Building a row formats every phone number in it, and this was being
    // rebuilt on each of the two places it is read.
    let rows = visible
    return TablePage {
      // ContentCard, not GlassCard. This card fills the page, and a glass surface that size
      // samples a page of whatever is behind the window; see `ContentCard`.
      ContentCard {
        VStack(alignment: .leading, spacing: 12) {
          explainer

          HStack(spacing: 10) {
            searchField
            Spacer()
            bulkMenu
          }

          if let message = screen.problem {
            ScreenErrorLine(message: message)
          } else if let status {
            Text(status).font(.caption).foregroundStyle(.secondary)
          }

          content(rows)

          pager
        }
      }
    }
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
      // Keyed on the SEARCH rather than on whether rows are loaded. With the filter in the
      // database an empty page and an empty index look identical from here, and telling
      // someone to grant Contacts access because their search found nothing sends them to
      // fix a permission that is working.
      ContentUnavailableView(
        query.search.isEmpty ? "No contacts indexed" : "No matches",
        systemImage: "person.crop.circle.badge.questionmark",
        description: Text(
          query.search.isEmpty
            ? "Grant Contacts access, then refresh to index your address book."
            : "No contact matches “\(query.search)”."
        )
      )
      // Fills, so it centres in the space under the header rather than sizing to its
      // content and dragging the header into the middle of the card with it. The table
      // below needs no such frame: it already fills.
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
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
      .clipShape(RoundedRectangle(cornerRadius: 8))
    }
  }

  /// The rows the table shows, in the order the DATABASE returned them.
  ///
  /// No filtering and no sorting here: both moved into the query, because a page is a window
  /// onto an ordered set and re-ordering the window shows the wrong rows. `Table`'s
  /// `sortOrder` binding still drives the column headers; it is translated into the query and
  /// the next read answers in that order.
  private var visible: [ContactRowItem] { rows }

  /// The flattened rows, built once per render rather than once per read of `visible`.
  private var rows: [ContactRowItem] { contacts.map(ContactRowItem.init) }

  /// "4,214 contacts", or how many match while a search is narrowing them.
  ///
  /// The count comes from the same read as the rows, so it counts what is in the INDEX and
  /// not what is on this page: a toolbar reading "100 contacts" on a Mac with four thousand
  /// is the old in-memory count wearing a new number.
  private var countSummary: String {
    guard query.search.isEmpty else { return "\(total.formatted(.number)) matching" }
    return total.counted("contact")
  }

  /// Where in the index this page sits, and the way to the next one.
  ///
  /// Shown whenever there is more than a page, and hidden when the whole index fits: a pager
  /// under a table of nine contacts is a control with nothing to do.
  @ViewBuilder
  private var pager: some View {
    if total > Self.pageSize {
      HStack(spacing: 10) {
        Text(query.summary(showing: contacts.count, total: total))
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()

        Spacer()

        Button {
          query.page(to: query.offset - Self.pageSize)
        } label: {
          Label("Previous", systemImage: "chevron.left")
        }
        .disabled(!query.hasPreviousPage)

        Button {
          query.page(to: query.offset + Self.pageSize)
        } label: {
          Label("Next", systemImage: "chevron.right")
        }
        .disabled(!query.hasNextPage(total: total, pageSize: Self.pageSize))
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }

  /// Switches contacts on or off, then re-reads so the page shows what is stored.
  ///
  /// Re-read rather than adjusted in place: the write can fail, and a switch that has moved on
  /// screen while the database says otherwise is the worst of the three possible states.
  private func setServed(_ served: Bool, ids: [String]) async {
    guard let interfaces = await model.messaging.interfaces() else { return }
    status = nil
    await screen.perform(failureMessage: "Could not change which contacts are served.") {
      try await interfaces.contact.setEnabled(served, ids: ids)
    }
    await screen.reload()
  }

  /// The bulk action, by the label the Account column shows.
  private func setServed(_ served: Bool, accountLabel: String) async {
    guard let interfaces = await model.messaging.interfaces() else { return }
    status = nil
    await screen.perform(failureMessage: "Could not change which contacts are served.") {
      let changed = try await interfaces.contact.setEnabled(served, accountLabel: accountLabel)
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
