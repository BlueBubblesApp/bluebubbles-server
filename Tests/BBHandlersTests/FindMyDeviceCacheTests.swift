//  FindMyDeviceCacheTests
//  What both FindMy device routes answer for each state the cache can be in.
//
//  `findmy/devices` and `findmy/devices/refresh` read the same file, and the refresh route
//  used to read it without the encryption guard: on Sequoia and later it parsed a binary
//  plist as JSON and answered 500 where the reference answers `data: null`. They share
//  `cachedDevices` so the two cannot drift again, and the states are pinned here rather than
//  left to whatever macOS the suite happens to run on.

import BBCore
import BBInterfaces
import BBSerialization
import Foundation
import Testing

@testable import BBHandlers

@Suite("FindMy device cache")
struct FindMyDeviceCacheTests {

  private struct Unreadable: Error {}

  private static let plaintext = Data(#"[{"name":"Test Device"}]"#.utf8)

  @Test("An encrypted cache is null, and is not read at all")
  func encryptedIsNull() {
    var wasRead = false
    let devices = FindMyInterface.cachedDevices(encrypted: true) {
      wasRead = true
      return Self.plaintext
    }
    #expect(devices == .null)
    #expect(!wasRead)
  }

  @Test("A readable plaintext cache is returned as parsed")
  func plaintextIsParsed() throws {
    let devices = FindMyInterface.cachedDevices(encrypted: false) { Self.plaintext }
    #expect(devices == (try JSONValue.parse(Self.plaintext)))
  }

  @Test("A cache that is missing, unreadable or not JSON is null rather than an error")
  func failuresAreNull() {
    #expect(FindMyInterface.cachedDevices(encrypted: false) { throw Unreadable() } == .null)
    #expect(FindMyInterface.cachedDevices(encrypted: false) { Data("bplist00".utf8) } == .null)
  }
}
