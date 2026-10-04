//  AuditLogView
//  What happened on this server, newest first.
//
//  A page over the `audit_event` table, paged by the DATABASE for the reason the Contacts page
//  is: this is the one table in `app.db` that is meant to grow, and a page that read a year
//  of records to show a hundred would be the contacts bug again. Every filter, the search and
//  the page offset go to `AuditRepository.page`, which answers with the rows and the total
//  from one read.
//
//  Three things the page deliberately does NOT do. It does not write a record of its own
//  reads: looking at the audit log is not an auditable action, or the log would be mostly
//  about itself. It does not edit or delete: records are the server's account of itself, and
//  the only thing that removes one is the retention sweep. And it does not reach the
//  recorder except to note an export, which IS an action, because a copy of the log left the
//  machine.
//
//  Reached only while the audit log is switched on: `SidebarDestinations` hides the row
//  otherwise, and the switched-off notice below covers the moment between the switch moving
//  and the row leaving.
//
//  See `docs/AUDIT_LOG.md` and `Sources/BlueBubblesApp/CLAUDE.md`.

import AppKit
import BBAudit
import BBBuiltIns
import BBServiceKit
import SwiftUI
import UniformTypeIdentifiers

/// What a change to means the page is read again: the feature being switched off, the
/// table moving, and the query itself. One key, because it is the same read whichever moved.
private struct ReloadTrigger: Hashable {
  let disabled: Bool
  let version: Int
  let query: String
}

/// One row of the table, flattened once per render rather than once per column.
private struct AuditRowItem: Identifiable {
  let event: AuditEvent
  /// The UUID rather than the row id: a row id is nil for a record that has not reached the
  /// database, and every record on this page has, but the identity a sheet is presented for
  /// should not depend on that.
  var id: UUID { event.uuid }
  let when: String
  let actor: String
  let subject: String

  init(_ event: AuditEvent, now: Date) {
    self.event = event
    self.when = AuditRowSummary.when(event.occurredAt, now: now)
    self.actor = AuditRowSummary.actor(event.actor)
    self.subject = AuditRowSummary.subject(event.subject)
  }
}

struct AuditLogView: View {

  @Bindable var model: AppModel
  @State private var screen: ScreenModel<AuditPage>
  /// What to ask the table for. A reference type because `ScreenModel`'s read is a closure
  /// built once, in `init`; see `AuditLogQuery`.
  @State private var query = AuditLogQuery()
  /// The record the detail sheet is open on.
  @State private var inspecting: AuditEvent?
  @State private var selection: UUID?
  /// What the last export did, which is a COUNT rather than a failure.
  @State private var status: String?

  /// How many records one page holds. Not a ceiling: everything older is one click away.
  static let pageSize = 100

  init(model: AppModel) {
    self.model = model
    let query = AuditLogQuery()
    _query = State(initialValue: query)
    _screen = State(initialValue: ScreenModel { try await Self.read(model, query) })
  }

  @MainActor
  private static func read(_ model: AppModel, _ query: AuditLogQuery) async throws -> AuditPage?
  {
    guard let repository = model.security.auditEvents else { return nil }
    // Not `(try? …) ?? empty`: a table that cannot be read must not look like a server on
    // which nothing has happened.
    return try await repository.page(
      query.repositoryQuery, limit: pageSize, offset: query.offset)
  }

  private var page: AuditPage? { screen.state.value }
  private var events: [AuditEvent] { page?.events ?? [] }
  /// How many records match the current filter, which is not how many are on screen.
  private var total: Int { page?.total ?? 0 }

  /// The integration this page is a view of. Nil only if the manifest is missing, which
  /// would mean a build without the built-in list.
  private var manifest: ServiceManifest? {
    IntegrationCatalog.manifest(BuiltInManifests.ID.auditLog)
  }

  private var isDisabled: Bool {
    guard let manifest else { return false }
    return !model.integrations.isEnabled(manifest)
  }

  var body: some View {
    Group {
      if !model.phase.isRunning {
        ServerStoppedNotice(
          model: model, placement: .page(symbol: "list.bullet.rectangle.portrait"),
          purpose: "view the audit log")
      } else if let manifest, isDisabled {
        // The whole page: with the feature off nothing is being recorded, so a table of old
        // rows would describe a server that has stopped keeping its account.
        ScrollView {
          GlassCard {
            FeatureDisabledNotice(
              manifest: manifest,
              model: model,
              consequence: "Nothing is being recorded: API requests, settings changes and "
                + "failed logins are leaving no trace. Records kept before it was switched "
                + "off are still here and are shown again as soon as it is turned back on."
            )
          }
          .padding(20)
        }
      } else {
        list
      }
    }
    .toolbar {
      if model.phase.isRunning, !isDisabled, total > 0 {
        Text(countSummary)
          .font(.callout)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Button {
        Task { await export() }
      } label: {
        Label("Export CSV…", systemImage: "square.and.arrow.up")
      }
      // Refusing rather than failing: with nothing to export the panel would save a header
      // line, and with the feature off the person should be sent to the switch instead.
      .disabled(screen.isPerforming || isDisabled || total == 0)
      .help("Save the records matching the current filter as a CSV file")

      if let manifest {
        Button {
          model.open(manifest.id)
        } label: {
          Label("Configure", systemImage: "slider.horizontal.3")
        }
        .help("Retention, read-only requests and syslog forwarding")
      }
    }
    // The switch lives on the Integrations screen AND on this page's own notice, so the
    // page has to reflect a change made either place.
    .task(id: model.phase.isRunning) { await model.integrations.refresh() }
    // Keyed on the feature, the table's version (which the model follows from the
    // repository's observation, so a request finishing on another thread moves it) and the
    // query, because all three change what the page should show and none changes the phase.
    .reloads(
      screen, following: model,
      alsoOn: ReloadTrigger(
        disabled: isDisabled, version: model.auditEventsVersion, query: query.reloadKey)
    )
    // A new filter or search redefines the pages, so it starts at the first one.
    .onChange(of: query.category) { _, _ in query.resetPaging() }
    .onChange(of: query.outcome) { _, _ in query.resetPaging() }
    .onChange(of: query.search) { _, _ in query.resetPaging() }
    // The sweep can remove the page the person is on. Pull the offset back into range, and
    // read again only if it moved.
    .onChange(of: total) { _, newTotal in
      if query.clamp(toTotal: newTotal, pageSize: Self.pageSize) {
        Task { await screen.reload() }
      }
    }
    .sheet(item: $inspecting) { event in
      AuditEventDetail(event: event)
    }
  }

  // MARK: - The list

  private var list: some View {
    let now = Date()
    let rows = events.map { AuditRowItem($0, now: now) }
    return TablePage {
      // ContentCard, not GlassCard: this card fills the page; see `ContentCard`.
      ContentCard {
        VStack(alignment: .leading, spacing: 12) {
          filters

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

  /// Category, outcome and a search, on the page beside the table they narrow.
  private var filters: some View {
    HStack(spacing: 10) {
      Picker("Category", selection: $query.category) {
        Text("All categories").tag(AuditCategory?.none)
        ForEach(AuditCategory.allCases, id: \.self) { category in
          Text(category.title).tag(AuditCategory?.some(category))
        }
      }
      .frame(maxWidth: 200)

      Picker("Outcome", selection: $query.outcome) {
        Text("Any outcome").tag(AuditOutcome?.none)
        ForEach(AuditOutcome.allCases, id: \.self) { outcome in
          Text(AuditRowSummary.outcome(outcome)).tag(AuditOutcome?.some(outcome))
        }
      }
      .frame(maxWidth: 160)

      searchField
      Spacer()
    }
    .labelsHidden()
  }

  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        // The field beside it is named, so this would be read out twice.
        .accessibilityHidden(true)

      TextField("Search records", text: $query.search)
        .textFieldStyle(.plain)

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

  @ViewBuilder
  private func content(_ rows: [AuditRowItem]) -> some View {
    if rows.isEmpty, screen.state.isLoading {
      // Ahead of the empty state: a table that has not been read yet also has no rows, and
      // "Nothing recorded yet" is an answer nobody has established.
      LoadingNotice(subject: "audit records")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if rows.isEmpty, screen.problem == nil {
      ContentUnavailableView(
        query.isFiltered ? "No matches" : "Nothing recorded yet",
        systemImage: "list.bullet.rectangle.portrait",
        description: Text(
          query.isFiltered
            ? "No record matches the current filter."
            : "Records appear here as requests are served, settings change and services "
              + "start and stop.")
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if !rows.isEmpty {
      Table(rows, selection: $selection) {
        TableColumn("When") { row in
          Text(row.when)
            .monospacedDigit()
            .help(AuditRowSummary.exactTime(row.event.occurredAt))
        }
        .width(min: 110, ideal: 130)

        TableColumn("Event") { row in
          Text(row.event.kind.title)
        }
        .width(min: 140, ideal: 180)

        TableColumn("Outcome") { row in
          Tag(AuditRowSummary.outcome(row.event.outcome), tint: tint(row.event.outcome))
        }
        .width(70)

        TableColumn("Who") { row in
          Text(row.actor).lineLimit(1).truncationMode(.middle)
        }
        .width(min: 120, ideal: 160)

        TableColumn("Summary") { row in
          Text(row.event.summary).lineLimit(1).truncationMode(.tail)
            .help(row.event.summary)
        }
      }
      // Double-click, or Return on the selected row, opens the record; the menu offers the
      // same so a person who does not double-click has a way in.
      .contextMenu(forSelectionType: UUID.self) { ids in
        if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
          Button("Show Details") { inspecting = row.event }
        }
      } primaryAction: { ids in
        if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
          inspecting = row.event
        }
      }
      // The table keeps its OWN opaque background; see `ContactsView` for why.
      .clipShape(RoundedRectangle(cornerRadius: 8))
    }
  }

  private func tint(_ outcome: AuditOutcome) -> Color? {
    switch AuditRowSummary.tone(outcome) {
    case .neutral: nil
    case .failed: .orange
    case .denied: .red
    }
  }

  /// "4,214 records", or how many match while a filter is narrowing them.
  private var countSummary: String {
    guard !query.isFiltered else { return "\(total.formatted(.number)) matching" }
    return total.counted("record")
  }

  @ViewBuilder
  private var pager: some View {
    if total > Self.pageSize {
      HStack(spacing: 10) {
        Text(query.summary(showing: events.count, total: total))
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()

        Spacer()

        Button {
          query.page(to: query.offset - Self.pageSize)
        } label: {
          Label("Newer", systemImage: "chevron.left")
        }
        .disabled(!query.hasPreviousPage)

        Button {
          query.page(to: query.offset + Self.pageSize)
        } label: {
          Label("Older", systemImage: "chevron.right")
        }
        .disabled(!query.hasNextPage(total: total, pageSize: Self.pageSize))
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }

  // MARK: - Export

  /// Writes the records matching the current filter to a file the person chooses, and
  /// records that it happened: an export is a copy of the log leaving the machine.
  ///
  /// The panel is plumbing and stays in the view; the file's name is `AuditRowSummary`'s.
  private func export() async {
    guard let repository = model.security.auditEvents else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.nameFieldStringValue = AuditRowSummary.exportFileName()
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }

    status = nil
    let filtered = query.isFiltered
    let repositoryQuery = query.repositoryQuery
    await screen.perform {
      let count = try await AuditCSVExporter(repository: repository)
        .export(matching: repositoryQuery, to: url)
      status = "Exported \(count.counted("record")) to \(url.lastPathComponent)."
      model.security.auditRecorder?.record(
        AuditEvent(
          kind: .exported,
          actor: .operator,
          source: .app,
          summary: "\(count.counted("audit record")) exported as CSV.",
          metadata: [
            "format": .string("csv"),
            "record_count": .int(count),
            "filtered": .bool(filtered),
          ]
        ))
    }
  }
}

// MARK: - Detail

/// One record, whole: the envelope as labelled fields and the metadata as the JSON document
/// a receiver would hold.
private struct AuditEventDetail: View {

  let event: AuditEvent
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text(event.kind.title).font(.title2.weight(.semibold))
        Text(event.summary).font(.body).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(20)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
            field("Kind", event.kind.rawValue)
            field("Category", event.category.rawValue)
            field("Outcome", AuditRowSummary.outcome(event.outcome))
            field("Severity", event.severity.rawValue)
            field("When", AuditRowSummary.exactTime(event.occurredAt))
            field("Who", AuditRowSummary.actor(event.actor))
            field("Source", event.source.rawValue)
            if let subject = event.subject {
              field("Subject", AuditRowSummary.subject(subject))
            }
            if let route = event.route {
              field("Route", route)
            }
            copyable("Request", event.requestID ?? "", placeholder: "Not part of a request")
            copyable("UUID", event.uuid.uuidString.lowercased(), placeholder: "Not stored")
          }

          VStack(alignment: .leading, spacing: 6) {
            Text("Metadata").font(.headline)
            // Selectable rather than copied by a button: it is a document, and the fields
            // a person wants are usually one or two of its lines.
            Text(AuditRowSummary.metadataJSON(event.metadata))
              .font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(10)
              .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
          }
        }
        .padding(20)
      }

      Divider()

      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(16)
    }
    .frame(minWidth: 520, idealWidth: 640, minHeight: 420, idealHeight: 560)
  }

  private func field(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
      Text(value).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func copyable(_ label: String, _ value: String, placeholder: String) -> some View {
    GridRow {
      Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
      CopyableValue(value, placeholder: placeholder)
    }
  }
}
