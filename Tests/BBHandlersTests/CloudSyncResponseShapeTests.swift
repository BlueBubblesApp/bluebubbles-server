//  CloudSyncResponseShapeTests
//  What `icloud/sync` emits, held against what the document says it emits.
//
//  Both routes' `data` is hand-declared in `ResponseBodies` (they have no recorded fixture;
//  see `docs/api/uncovered-routes.txt`), so nothing else executes the serializer and compares
//  its keys to the declaration. The shape is the same with every optional field missing,
//  which is the half that matters: a field this Mac could not read is `null`, never dropped,
//  so a decoder generated from the document holds on every release.

import BBHTTPAPI
import BBInterfaces
import BBOpenAPI
import BBPrivateAPIContract
import Foundation
import Testing

@Suite("The iCloud sync responses match what the document declares")
struct CloudSyncResponseShapeTests {

  private func declared(_ handler: HandlerID) -> Set<String> {
    guard let body = ResponseBodies.byHandler[handler] else { return [] }
    return Set(body.variants.flatMap { $0.properties.map(\.name) })
  }

  @Test(
    "Both routes declare the serializer's keys, complete or not",
    arguments: [
      CloudSyncState(
        isEnabled: true, isSyncing: true, lastSyncDate: Date(timeIntervalSince1970: 1_700_000_000),
        isPaused: false, failed: false, statusText: "Syncing 3 messages"),
      CloudSyncState(isEnabled: false, isSyncing: false, lastSyncDate: nil),
    ])
  func keysMatch(_ state: CloudSyncState) {
    let emitted = Set(AccountInterface.cloudSyncPayload(state).keys)
    for handler in [HandlerID.icloudSyncState, .icloudStartSync] {
      #expect(emitted == declared(handler), "\(handler)")
    }
  }

  @Test("A field this Mac could not read is null, not false")
  func unknownIsNull() {
    let payload = AccountInterface.cloudSyncPayload(
      CloudSyncState(isEnabled: true, isSyncing: false, lastSyncDate: nil))
    #expect(payload["paused"] == .null)
    #expect(payload["failed"] == .null)
    #expect(payload["status_text"] == .null)
    #expect(payload["last_sync_at"] == .null)
  }
}
