//  ContactsView
//  The contact index, and a way to re-read the address book.

import BBContacts
import BBInterfaces
import BlueBubblesServerCore
import SwiftUI

struct ContactsView: View {

  @Bindable var model: AppModel
  @State private var screen: ScreenModel<[ContactRecord]>
  @State private var search = ""
  /// The outcome of the last re-index, which is a COUNT rather than a failure — "indexed
  /// 412, skipped 3". Kept apart from the model's error channel because it is the success
  /// message far more often than not.
  @State private var status: String?

  init(model: AppModel) {
    self.model = model
    _screen = State(initialValue: ScreenModel { try await Self.read(model) })
  }

  @MainActor
  private static func read(_ model: AppModel) async throws -> [ContactRecord]? {
    guard let interfaces = await model.interfaces() else { return nil }
    // Was `(try? …) ?? []`, so a contact index that could not be read looked exactly
    // like an address book with nobody in it — and the empty state told the person to
    // grant Contacts access they may already have granted.
    return try await interfaces.contact.list(limit: 5000)
  }

  private var contacts: [ContactRecord] { screen.state.value ?? [] }

  var body: some View {
    Group {
      if !model.phase.isRunning {
        ContentUnavailableView(
          "Server not running",
          systemImage: "person.crop.circle",
          description: Text("Start the server to view contacts.")
        )
      } else {
        list
      }
    }
    .searchable(text: $search, prompt: "Search contacts")
    .toolbar {
      Button {
        Task { await refresh() }
      } label: {
        Label("Refresh from Address Book", systemImage: "arrow.clockwise")
      }
      .disabled(screen.isPerforming)
    }
    .task { await screen.reload() }
  }

  private var list: some View {
    VStack(spacing: 0) {
      if let message = screen.problem {
        ScreenErrorLine(message: message).padding(8)
      } else if let status {
        Text(status).font(.caption).foregroundStyle(.secondary).padding(8)
      }
      if visible.isEmpty {
        ContentUnavailableView(
          contacts.isEmpty ? "No contacts indexed" : "No matches",
          systemImage: "person.crop.circle.badge.questionmark",
          description: Text(
            contacts.isEmpty
              ? "Grant Contacts access, then refresh to index your address book."
              : "No contact matches “\(search)”."
          )
        )
      } else {
        Table(visible.map(ContactRowItem.init)) {
          TableColumn("Name") { Text($0.name) }
          TableColumn("Phone") { Text($0.phones).monospacedDigit() }
          TableColumn("Email") { Text($0.emails) }
          // The ACCOUNT, not the storage origin. "api"/"db" is what the wire format
          // has always called address-book vs server-created, and it answers a
          // question nobody was asking while hiding the one they were.
          TableColumn("Account") { row in
            if let account = row.account {
              Text(account)
            } else {
              Text(row.source).foregroundStyle(.secondary)
            }
          }
        }
      }
    }
  }

  private var visible: [ContactRecord] {
    guard !search.isEmpty else { return contacts }
    return contacts.filter {
      ContactRowItem($0).searchText.localizedCaseInsensitiveContains(search)
    }
  }

  private func refresh() async {
    guard let interfaces = await model.interfaces() else { return }
    status = nil
    // The likely cause, named. "Operation failed" would send someone hunting.
    await screen.perform(
      failureMessage: "Could not read the address book — check Contacts permission."
    ) {
      let result = try await interfaces.contact.refresh()
      status = "Indexed \(result.indexed), skipped \(result.skipped)."
    }
  }
}

/// A flattened row.
///
/// `ContactRecord` is already `Identifiable`, so this no longer has to invent an id out of
/// a row index — it exists purely to turn a record into the four strings the table shows.
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
  /// This read `value["sourceName"]` before, and the serializer never emitted that key — so
  /// it was nil for every row and the column always showed the fallback below. Reading the
  /// record directly is what surfaced it: an absent key is silent, an absent property does
  /// not compile.
  var account: String? { record.account?.label }
  /// Shown only as a fallback, for rows indexed before accounts were recorded.
  var source: String {
    switch record.source {
    case .macOS: "Address Book"
    case .local: "Local"
    }
  }
  // Searches the RAW addresses as well as the formatted ones, so typing a bare "5550101234"
  // still finds a number displayed as "(555) 010-1234".
  var searchText: String {
    ([name, phones, emails] + record.phoneNumbers + record.emailAddresses)
      .joined(separator: " ")
  }
}
