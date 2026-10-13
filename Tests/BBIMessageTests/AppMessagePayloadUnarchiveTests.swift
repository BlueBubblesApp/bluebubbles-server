//  AppMessagePayloadUnarchiveTests
//  `payload_data` is unarchived against an allowlist, and still reads what Messages writes.
//
//  The bytes come from whoever sent the message, so an unarchive that instantiates any
//  class this process has loaded runs that class's `initWithCoder:` on a stranger's input.
//  Two things have to hold at once: such a class is refused before it runs, and a class
//  name this process does not have at all is still stood in for, because an app's own
//  layout class must not cost the whole envelope.

import Foundation
import Testing

@testable import BBIMessage

/// A class this process HAS and the allowlist does not name. Records whether it ran.
@objc(BBUnarchiveTripwire)
private final class Tripwire: NSObject, NSCoding {
  nonisolated(unsafe) static var decoded = false
  override init() { super.init() }
  required init?(coder: NSCoder) {
    Tripwire.decoded = true
    super.init()
  }
  func encode(with coder: NSCoder) {}
}

/// Archived under a class name nothing in this process has, as an app's layout would be.
@objc(BBUnarchiveForeignLayout)
private final class ForeignLayout: NSObject, NSCoding {
  override init() { super.init() }
  required init?(coder: NSCoder) { super.init() }
  func encode(with coder: NSCoder) { coder.encode("caption", forKey: "caption") }
}

@Suite("App payload unarchiving")
struct AppMessagePayloadUnarchiveTests {

  private func archive(_ root: NSDictionary, renaming: [(AnyClass, String)] = []) -> Data {
    let archiver = NSKeyedArchiver(requiringSecureCoding: false)
    for (type, name) in renaming { archiver.setClassName(name, for: type) }
    archiver.encode(root, forKey: NSKeyedArchiveRootObjectKey)
    archiver.finishEncoding()
    return archiver.encodedData
  }

  @Test("A loaded class outside the allowlist is refused before its initialiser runs")
  func refusesALoadedClass() {
    Tripwire.decoded = false
    let data = archive(["an": "Polls", "URL": NSURL(string: "data:,e30=")!, "x": Tripwire()])
    #expect(AppMessagePayload.envelope(from: data) == nil)
    #expect(!Tripwire.decoded)
  }

  @Test("A class name this process does not have is stood in for, and the rest still reads")
  func substitutesAnUnknownClass() throws {
    let session = UUID()
    let data = archive(
      [
        "an": "Polls", "URL": NSURL(string: "data:,e30=")!,
        "sessionIdentifier": session as NSUUID, "liveLayoutInfo": ForeignLayout(),
      ],
      renaming: [(ForeignLayout.self, "MSMessageLiveLayout")])
    let envelope = try #require(AppMessagePayload.envelope(from: data))
    #expect(envelope.appName == "Polls")
    #expect(envelope.sessionID == session.uuidString)
  }

  /// The census shape: what Messages wrote for every app payload on the machine measured.
  @Test("Mutable dictionaries, mutable data, URLs and UUIDs all decode")
  func readsTheMeasuredClasses() throws {
    let root = NSMutableDictionary(dictionary: [
      "an": "GamePigeon", "URL": NSURL(string: "data:?game=pool")!,
      "sessionIdentifier": NSUUID(), "appid": NSNumber(value: 1_124_197_642),
      "ai": NSMutableData(data: Data([1, 2, 3])), "ldtext": "Your move.",
      "userInfo": NSMutableDictionary(dictionary: ["caption": "Your move."]),
      "liveLayoutInfo": NSMutableData(data: Data([4])),
    ])
    let envelope = try #require(AppMessagePayload.envelope(from: archive(root)))
    #expect(envelope.url == "data:?game=pool")
    #expect(envelope.appID == 1_124_197_642)
    #expect(envelope.caption == "Your move.")
    #expect(AppMessagePayload.icon(in: archive(root)) == Data([1, 2, 3]))
  }
}
