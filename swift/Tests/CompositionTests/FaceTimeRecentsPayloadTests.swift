//  FaceTimeRecentsPayloadTests
//  The WIRE shape of `GET facetime/recents`.
//
//  Separate from CallHistoryRepositoryTests, which covers reading the database. These cover
//  the mapping OUT of Apple's vocabulary into the API's — the part a client sees, and the
//  part that would quietly drift back toward the column names.
//
//  NO REAL ADDRESSES — see CONTRIBUTING.md.

import BBPrivateAPIContract
import BBSerialization
import BBSystem
import Foundation
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("FaceTime recents payload")
struct FaceTimeRecentsPayloadTests {

  private func record(
    id: String = "CALL-1",
    address: String? = "person@example.com",
    displayName: String? = "Example Person",
    date: Date = Date(timeIntervalSince1970: 1_756_515_965),
    duration: TimeInterval = 16,
    isOutgoing: Bool = true,
    isAnswered: Bool = false,
    isVideo: Bool = true,
    service: String? = "com.apple.FaceTime",
    groupUUID: String? = "20618F91-D005-4B81-BD58-0EFF09CB0A0F",
    participants: [String] = ["person@example.com"]
  ) -> CallRecord {
    CallRecord(
      id: id, address: address, displayName: displayName, date: date,
      duration: duration, isOutgoing: isOutgoing, isAnswered: isAnswered,
      isVideo: isVideo, service: service, groupUUID: groupUUID,
      participants: participants
    )
  }

  /// `call_uuid`, not `id`: the value IS `TUCall.callUUID`, and `callObject` already spells
  /// it that way — so a recents entry correlates with a live call a client is holding.
  @Test("The identifier is call_uuid, matching the live call object")
  func identifierMatchesCallObject() {
    let payload = FaceTimeHandlers.callRecordObject(record())
    #expect(payload["call_uuid"]?.stringValue == "CALL-1")
    #expect(payload["id"] == nil)
  }

  /// Every other time value this API returns is milliseconds. The columns are neither:
  /// `ZDATE` is seconds since 2001 and `ZDURATION` is float seconds.
  @Test("Times are milliseconds, so date_created + duration is meaningful")
  func timesAreMilliseconds() {
    let payload = FaceTimeHandlers.callRecordObject(record())
    #expect(payload["date_created"]?.intValue == 1_756_515_965_000)
    #expect(payload["duration"]?.intValue == 16_000)
    #expect(payload["date"] == nil)
  }

  /// Elsewhere `service` is a name a client displays ("iMessage", "SMS"), never a bundle id.
  @Test("Service is a display name, not Apple's bundle identifier")
  func serviceIsADisplayName() {
    #expect(FaceTimeHandlers.serviceName("com.apple.FaceTime") == "FaceTime")
    #expect(FaceTimeHandlers.serviceName("com.apple.Telephony") == "Phone")
    let payload = FaceTimeHandlers.callRecordObject(record())
    #expect(payload["service"]?.stringValue == "FaceTime")
  }

  /// A provider we have not seen is reported verbatim. Flattening it into "Phone" would
  /// mislabel it, and a wrong name is worse than an unfamiliar one.
  @Test("An unknown provider passes through rather than being mislabelled")
  func unknownProviderPassesThrough() {
    #expect(
      FaceTimeHandlers.serviceName("com.example.someprovider")
        == "com.example.someprovider")
  }

  /// `chat.participants` are handle objects. Bare strings here would force a client to
  /// keep a second code path for the same concept.
  @Test("Participants are handle objects, like chat.participants")
  func participantsAreObjects() {
    let payload = FaceTimeHandlers.callRecordObject(
      record(participants: [
        "temp:11111111-2222-3333-4444-555555555555",
        "person@example.com",
      ])
    )
    let participants = try? #require(payload["participants"]?.arrayValue)
    #expect(participants?.count == 2)
    // A link guest has no FaceTime address — the throwaway handle is what there is.
    #expect(
      participants?.first?["address"]?.stringValue
        == "temp:11111111-2222-3333-4444-555555555555")
    #expect(participants?.last?["address"]?.stringValue == "person@example.com")
  }

  /// There is no missed column: the log records direction and answer separately.
  @Test("Missed means incoming and unanswered, never outgoing")
  func missedIsDerived() {
    let unansweredOutgoing = FaceTimeHandlers.callRecordObject(
      record(isOutgoing: true, isAnswered: false)
    )
    #expect(unansweredOutgoing["is_missed"]?.boolValue == false)

    let unansweredIncoming = FaceTimeHandlers.callRecordObject(
      record(isOutgoing: false, isAnswered: false)
    )
    #expect(unansweredIncoming["is_missed"]?.boolValue == true)

    let answeredIncoming = FaceTimeHandlers.callRecordObject(
      record(isOutgoing: false, isAnswered: true)
    )
    #expect(answeredIncoming["is_missed"]?.boolValue == false)
  }

  /// The inherited `session` and `answer` routes are Node's, and Node answers them with
  /// `data.link` — a bare URL string. Returning only `data.url` broke every existing client
  /// reading `data.link`, on the two FaceTime routes that already shipped.
  @Test("Inherited routes carry data.link for Node clients")
  func inheritedPayloadCarriesLink() {
    let payload = FaceTimeHandlers.inheritedLinkPayload(
      FaceTimeLink(
        url: "https://facetime.apple.com/join#v=1&p=abc",
        groupUUID: "11111111-2222-3333-4444-555555555555"
      )
    )
    #expect(payload["link"]?.stringValue == "https://facetime.apple.com/join#v=1&p=abc")
    // The richer fields ride along; extra keys are harmless to a client that ignores them.
    #expect(payload["url"]?.stringValue == "https://facetime.apple.com/join#v=1&p=abc")
    #expect(payload["group_uuid"]?.stringValue == "11111111-2222-3333-4444-555555555555")
  }

  /// Absent rather than null, matching how the other FaceTime payloads handle what macOS
  /// did not record.
  @Test("Fields macOS did not record are omitted, not null")
  func omitsMissingFields() {
    let payload = FaceTimeHandlers.callRecordObject(
      record(
        address: nil, displayName: nil, service: nil, groupUUID: nil,
        participants: [])
    )
    #expect(payload["display_name"] == nil)
    #expect(payload["group_uuid"] == nil)
    #expect(payload["service"] == nil)
    #expect(payload["address"] == nil)
    // The array is still present — an empty list is a real answer.
    #expect(payload["participants"]?.arrayValue?.isEmpty == true)
  }
}
