//  AppMessageIconTests
//  The balloon artwork survives a round trip through the archive.
//
//  `ai` is the one field in an app payload this server cannot invent: a Mac generally has no
//  third-party iMessage extension installed, so there is no local icon to read. It comes
//  from a message the app itself sent, which makes reading it out of an archive and writing
//  it back into one the whole mechanism — and worth pinning, because a silent failure here
//  is a bare balloon that looks like the send went wrong.

import Foundation
import Testing

@testable import BBIMessage

@Suite("App message icon")
struct AppMessageIconTests {

  /// Not a real icon — a byte pattern that would survive nothing but an exact round trip.
  private var artwork: Data {
    Data((0..<512).map { UInt8($0 % 251) })
  }

  private func encoded(icon: Data?) throws -> Data {
    try AppMessagePayload.encode(
      url: "data:?game=pool&id=abc",
      sessionID: UUID(uuidString: "2B62987D-4F1C-4A2E-9C3D-6E5B1A7F0C22")!,
      appName: "GamePigeon", appID: 1_124_197_642, summary: "Your move.",
      caption: "Your move.", icon: icon
    )
  }

  @Test("An icon written into the archive reads back byte for byte")
  func iconRoundTrips() throws {
    let payload = try encoded(icon: artwork)
    #expect(AppMessagePayload.icon(in: payload) == artwork)
  }

  @Test("No icon means no `ai` key, not an empty one")
  func absentIconIsAbsent() throws {
    // An empty `ai` would be a claim that the app has no artwork, which is different from
    // this Mac not having any to send.
    #expect(AppMessagePayload.icon(in: try encoded(icon: nil)) == nil)
    #expect(AppMessagePayload.icon(in: try encoded(icon: Data())) == nil)
  }

  @Test("The icon does not disturb the rest of the payload")
  func otherFieldsSurvive() throws {
    // The archive is a flat dictionary and `ai` is the largest thing in it, so this is the
    // edit most likely to break its neighbours.
    let payload = try encoded(icon: artwork)
    let decoded = try #require(AppMessagePayload.envelope(from: payload))
    #expect(decoded.url == "data:?game=pool&id=abc")
    #expect(decoded.appName == "GamePigeon")
    #expect(decoded.appID == 1_124_197_642)
    #expect(decoded.caption == "Your move.")
    #expect(decoded.sessionID == "2B62987D-4F1C-4A2E-9C3D-6E5B1A7F0C22")
  }

  @Test("Nothing that is not an archive is mistaken for one carrying an icon")
  func rubbishYieldsNoIcon() {
    #expect(AppMessagePayload.icon(in: Data()) == nil)
    #expect(AppMessagePayload.icon(in: Data("not a plist".utf8)) == nil)
  }
}
