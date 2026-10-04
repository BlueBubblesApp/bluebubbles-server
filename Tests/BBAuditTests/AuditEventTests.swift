//  AuditEventTests
//  The envelope every consumer of the audit log reads, and the defaults it takes from the
//  work in flight.
//
//  The two decisions worth pinning are the ones a reviewer cannot see from a call site: a
//  record written with nothing set is the OPERATOR's doing, because every other boundary sets
//  the actor explicitly and what is left is the person at the Mac; and a record written inside
//  a request inherits the request's id, which is what joins the domain record to the
//  transport record afterwards.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBCore
import Foundation
import Testing

@testable import BBAudit

@Suite("Audit event envelope")
struct AuditEventTests {

  @Test("With no context set, the actor is the operator and the source is the app")
  func fallbackActorIsTheOperator() {
    let event = AuditEvent(kind: .settingsChanged, summary: "x")
    #expect(event.actor == .operator)
    #expect(event.source == .app)
    #expect(event.requestID == nil)
  }

  @Test("A record written inside a request carries the request's actor, id and route")
  func inheritsTheRequestContext() async {
    let context = AuditContext(
      actor: .client(address: "203.0.113.9"), source: .http, requestID: "req-1",
      route: "/api/v1/chat/:guid/read")
    let event = await AuditContext.with(context) {
      AuditEvent(kind: .webhookCreated, summary: "x")
    }
    #expect(event.actor == .client(address: "203.0.113.9"))
    #expect(event.source == .http)
    #expect(event.requestID == "req-1")
    #expect(event.route == "/api/v1/chat/:guid/read")
  }

  @Test("A task spawned inside the context inherits it")
  func childTasksInherit() async {
    let event = await AuditContext.acting(as: .system(component: "startup")) {
      await Task { AuditEvent(kind: .serviceStarted, summary: "x") }.value
    }
    #expect(event.actor == .system(component: "startup"))
    #expect(event.source == .server)
  }

  @Test("An explicit actor wins over the context")
  func explicitActorWins() async {
    let event = await AuditContext.acting(as: .operator) {
      AuditEvent(kind: .clientBlocked, actor: .system(component: "access-control"), summary: "x")
    }
    #expect(event.actor == .system(component: "access-control"))
  }

  // MARK: - Severity

  @Test("A refusal is at least a warning whatever the kind's base severity")
  func refusalsAreWarnings() {
    #expect(AuditEvent(kind: .apiRequest, outcome: .success, summary: "x").severity == .info)
    #expect(AuditEvent(kind: .apiRequest, outcome: .denied, summary: "x").severity == .warning)
    #expect(AuditEvent(kind: .apiRequest, outcome: .failure, summary: "x").severity == .warning)
    #expect(AuditEvent(kind: .eventsDropped, outcome: .failure, summary: "x").severity == .critical)
  }

  // MARK: - The document

  @Test("The document carries every envelope key, with nulls for what is absent")
  func documentShape() {
    let event = AuditEvent(kind: .recordingStarted, summary: "Started.")
    let document = event.document(hostname: "mac.example.com")
    let expected: Set<String> = [
      "schema_version", "uuid", "occurred_at", "category", "kind", "outcome", "severity",
      "actor", "source", "request_id", "route", "subject", "summary", "metadata", "host",
    ]
    #expect(Set(document.keys) == expected)
    #expect(document["request_id"] == .null)
    #expect(document["subject"] == .null)
    #expect(document["kind"] == .string("audit.recording_started"))
    #expect(document["category"] == .string("audit"))
    #expect(document["schema_version"] == .int(AuditEvent.schemaVersion))
    // The row id is present only once stored.
    #expect(document["id"] == nil)
  }

  @Test("Metadata values survive a JSON round trip with their types")
  func valuesRoundTrip() throws {
    let value = AuditValue.object([
      "string": .string("a,b"),
      "int": .int(42),
      "double": .double(1.5),
      "bool": .bool(true),
      "null": .null,
      "array": .array([.string("x"), .int(1)]),
      "nested": .object(["k": .bool(false)]),
    ])
    let data = try AuditJSON.encode(value)
    let decoded = try AuditJSON.decode(AuditValue.self, from: data)
    #expect(decoded == value)
  }

  @Test("The JSON is deterministic: sorted keys, slashes unescaped")
  func jsonIsDeterministic() throws {
    let data = try AuditJSON.encode(AuditValue.object(["b": .string("/x"), "a": .int(1)]))
    #expect(String(decoding: data, as: UTF8.self) == #"{"a":1,"b":"/x"}"#)
  }

  @Test("The timestamp is RFC 3339 UTC with milliseconds, and reads back")
  func timestampShape() {
    let date = Date(timeIntervalSince1970: 1_700_000_000.123)
    let text = AuditTimestamp.string(from: date)
    #expect(text == "2023-11-14T22:13:20.123Z")
    let parsed = AuditTimestamp.date(from: text)
    #expect(parsed.map { abs($0.timeIntervalSince(date)) < 0.001 } == true)
  }

  // MARK: - Kinds

  @Test("Every kind's raw value is its category's raw value, a dot, and a snake_case name")
  func kindsAreNamespacedByCategory() {
    for kind in AuditEventKind.allCases {
      let parts = kind.rawValue.split(separator: ".", maxSplits: 1)
      #expect(parts.count == 2, "\(kind.rawValue) is not category.name")
      #expect(
        String(parts[0]) == kind.category.rawValue, "\(kind.rawValue) names the wrong category")
      let name = String(parts[1])
      #expect(
        name.allSatisfy { $0.isLowercase || $0 == "_" || $0.isNumber },
        "\(kind.rawValue) is not snake_case")
    }
  }

  @Test("Every kind has a title and every metadata field a description")
  func kindsAreDescribed() {
    for kind in AuditEventKind.allCases {
      #expect(!kind.title.isEmpty)
      for field in kind.metadataFields {
        #expect(!field.description.isEmpty, "\(kind.rawValue).\(field.name) has no description")
        #expect(
          field.name.allSatisfy { $0.isLowercase || $0 == "_" },
          "\(kind.rawValue).\(field.name) is not snake_case")
      }
      // A kind declares each field once.
      let names = kind.metadataFields.map(\.name)
      #expect(Set(names).count == names.count, "\(kind.rawValue) declares a field twice")
    }
  }

  @Test("The redacted marker is what a secret's value becomes")
  func redactedMarker() {
    #expect(AuditValue.redacted == .string("••••"))
    #expect(AuditValue.redacted.displayText == "••••")
  }
}
