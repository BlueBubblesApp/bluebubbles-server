//  ContactsView
//  The contact index, and a way to re-read the address book.

import BBContacts
import BBHandlers
import BBInterfaces
import BlueBubblesServerCore
import SwiftUI

struct ContactsView: View {

  @Bindable var model: AppModel
  @State private var contacts: [ContactRecord] = []
  @State private var search = ""
  @State private var isRefreshing = false
  @State private var status: String?

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
      .disabled(isRefreshing)
    }
    .task { await reload() }
  }

  private var list: some View {
    VStack(spacing: 0) {
      if let status {
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

  private func reload() async {
    guard let interfaces = await model.interfaces() else { return }
    contacts = (try? await interfaces.contact.records(limit: 5000)) ?? []
  }

  private func refresh() async {
    guard let interfaces = await model.interfaces() else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    do {
      let result = try await interfaces.contact.refresh()
      status =
        "Indexed \(result["indexed"]?.intValue ?? 0), "
        + "skipped \(result["skipped"]?.intValue ?? 0)."
      await reload()
    } catch {
      // The likely cause, named. "Operation failed" would send someone hunting.
      status = "Could not read the address book — check Contacts permission."
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
