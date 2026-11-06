//  AppMessageLiveLayoutTests
//  The live-layout marker is a second archive inside the first, and nothing else moves.
//
//  Every message a current Game Pigeon sends carries `liveLayoutInfo`: a keyed archive of
//  `{layoutClass: MSMessageLiveLayout, userInfo: {}}` as data, beside a top-level
//  `layoutClass` that stays the template. A balloon without it renders as the template on
//  the recipient's device, the caption and the icon rather than the game, which is the
//  difference a client noticed between its turns and the phone's. These pin the shape, that
//  it is opt-in, and that the reader sees it.

import Foundation
import Testing

@testable import BBIMessage

@Suite("App message live layout")
struct AppMessageLiveLayoutTests {

  private func encoded(live: Bool) throws -> Data {
    try AppMessagePayload.encode(
      url: "data:?game=pool&id=abc",
      sessionID: UUID(uuidString: "2B62987D-4F1C-4A2E-9C3D-6E5B1A7F0C22")!,
      appName: "GamePigeon", appID: 1_124_197_642, summary: "Your move.",
      caption: "Your move.", liveLayout: live)
  }

  @Test("`liveLayout` writes a nested archive of exactly the measured dictionary")
  func markerIsANestedArchive() throws {
    let payload = try encoded(live: true)
    let root = try #require(AppMessagePayload.root(of: payload))
    let inner = try #require(root["liveLayoutInfo"] as? Data)
    let decoded = try #require(
      try NSKeyedUnarchiver.unarchivedObject(
        ofClasses: [NSDictionary.self, NSString.self], from: inner) as? [String: Any])
    #expect(decoded["layoutClass"] as? String == "MSMessageLiveLayout")
    #expect((decoded["userInfo"] as? [String: Any])?.isEmpty == true)
    #expect(decoded.count == 2)
    // The size a genuine marker has; a different one means a different graph.
    #expect(inner.count == 318)
    // The template stays, as the live layout's alternate.
    #expect(root["layoutClass"] as? String == "MSMessageTemplateLayout")
    #expect(AppMessagePayload.hasLiveLayout(in: payload))
  }

  @Test("Absent unless asked for, not written empty")
  func absentByDefault() throws {
    let payload = try encoded(live: false)
    #expect(AppMessagePayload.root(of: payload)?["liveLayoutInfo"] == nil)
    #expect(!AppMessagePayload.hasLiveLayout(in: payload))
  }

  @Test("The marker does not disturb the envelope")
  func envelopeSurvives() throws {
    let decoded = try #require(AppMessagePayload.envelope(from: try encoded(live: true)))
    #expect(decoded.url == "data:?game=pool&id=abc")
    #expect(decoded.appName == "GamePigeon")
    #expect(decoded.caption == "Your move.")
    #expect(decoded.sessionID == "2B62987D-4F1C-4A2E-9C3D-6E5B1A7F0C22")
  }

  @Test("Nothing that is not an archive reads as live")
  func rubbishIsNotLive() {
    #expect(!AppMessagePayload.hasLiveLayout(in: Data([1, 2, 3])))
    #expect(!AppMessagePayload.hasLiveLayout(in: Data()))
  }
}
