//  SucceedingHelpers
//  Doubles that let an operation REACH a result, one role at a time.
//
//  `FailingPrivateAPI` next door throws from every member, which is why it was writable at
//  all against a seventy-six-member protocol: no return value has to be constructed. It
//  answers "is this operation wrapped in `throughMessages`" and nothing else. Every question
//  on the other side of the helper — did the interface send what the caller asked for, does
//  it hand back what the helper returned — had no fake to ask it with.
//
//  Roles are what make the succeeding half affordable. `HandleAvailability` is three methods,
//  so a stub that answers them is a dozen lines rather than a seventy-six-member obligation
//  where seventy-three of the members exist to be ignored.
//
//  Two rules for the stubs below:
//
//    1. **Record what was asked, do not just answer.** Half of what these tests are for is
//       that the interface passed the right thing DOWN — `availability` picking the FaceTime
//       call over the iMessage one is invisible to a stub that only returns a Bool.
//    2. **Refuse what the test did not arrange.** An unset expectation throws rather than
//       returning a default, so a test that drives an unexpected path fails there instead of
//       passing on a zero value that means nothing.

import BBPrivateAPIContract
import Foundation

/// Thrown by any stub member a test did not arrange. See rule 2 above.
public struct StubNotArranged: Error, CustomStringConvertible {
  public let member: String
  public var description: String { "the test did not arrange \(member)" }
}

// MARK: - HandleAvailability

/// `HandleInterface`'s whole helper surface: three questions about one address.
public final class StubHandleAvailability: HandleAvailability, @unchecked Sendable {

  /// What each answer will be. Nil means "not arranged" — see `StubNotArranged`.
  public var iMessage: Bool?
  public var faceTime: Bool?
  public var focus: String?

  /// Every address this was asked about, in order, tagged with which question was asked.
  ///
  /// The tag is the point: `availability(address:service:)` chooses between two helper calls
  /// off its `service` argument, and a stub that recorded only the address could not tell a
  /// test whether the choice was made correctly.
  public private(set) var asked: [(question: String, address: String)] = []

  public init(iMessage: Bool? = nil, faceTime: Bool? = nil, focus: String? = nil) {
    self.iMessage = iMessage
    self.faceTime = faceTime
    self.focus = focus
  }

  public func checkIMessageAvailability(address: String) async throws -> Bool {
    asked.append(("iMessage", address))
    guard let iMessage else { throw StubNotArranged(member: "checkIMessageAvailability") }
    return iMessage
  }

  public func checkFaceTimeAvailability(address: String) async throws -> Bool {
    asked.append(("faceTime", address))
    guard let faceTime else { throw StubNotArranged(member: "checkFaceTimeAvailability") }
    return faceTime
  }

  public func checkFocusStatus(address: String) async throws -> String {
    asked.append(("focus", address))
    guard let focus else { throw StubNotArranged(member: "checkFocusStatus") }
    return focus
  }
}

// MARK: - AttachmentAccess

/// `AttachmentInterface`'s whole helper surface: one method.
///
/// The extreme case for the role split, and the clearest: recovering a purged attachment was
/// unreachable in a test because the only conformer available threw, and the one method it
/// needs is one member out of seventy-six.
public final class StubAttachmentAccess: AttachmentAccess, @unchecked Sendable {

  /// The path iCloud recovery will report, or nil to refuse.
  public var recoveredPath: String?
  public private(set) var requested: [String] = []

  public init(recoveredPath: String? = nil) {
    self.recoveredPath = recoveredPath
  }

  public func downloadPurgedAttachment(guid: String) async throws -> String {
    requested.append(guid)
    guard let recoveredPath else { throw StubNotArranged(member: "downloadPurgedAttachment") }
    return recoveredPath
  }
}
