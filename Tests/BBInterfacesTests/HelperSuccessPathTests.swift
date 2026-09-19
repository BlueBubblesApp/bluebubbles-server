//  HelperSuccessPathTests
//  What an interface does when the helper ANSWERS.
//
//  Every existing suite over this layer drives a helper that refuses: `ChatFailureTests`,
//  `SendFailureTests`, `InterfaceFailureTests` all take `FailingPrivateAPI`. That was not a
//  gap anyone chose: `PrivateAPI` was one protocol of seventy-six members with no defaults, so
//  the only affordable conformance was one that throws from every member, and the success side
//  of every Private-API operation went unasserted.
//
//  These are the first tests on the other side of that. They are deliberately about the
//  interface's own behaviour rather than the helper's (what it passed down, what it did with
//  what came back) because that is the half a failing double can never reach.
//
//  See `SucceedingHelpers.swift`.

import BBInterfaces
import BBPrivateAPIContract
import BBTestSupport
import Foundation
import Testing

@Suite("Interfaces, when the helper answers")
struct HelperSuccessPathTests {

  // MARK: - HandleInterface

  @Test("availability asks the service the caller named, not the other one")
  func availabilityRoutesByService() async throws {
    let helper = StubHandleAvailability(iMessage: true, faceTime: false)
    let interface = HandleInterface(
      repository: try InterfaceFixtures.repository(), privateAPI: helper
    )

    let onIMessage = try await interface.availability(
      address: "user@example.invalid", service: .iMessage
    )
    let onFaceTime = try await interface.availability(
      address: "user@example.invalid", service: .faceTime
    )

    #expect(onIMessage)
    #expect(!onFaceTime)
    // The answers differ, so a stub returning one value for both could not have produced
    // this: the interface picked a different helper call for each service.
    #expect(helper.asked.map(\.question) == ["iMessage", "faceTime"])
    #expect(helper.asked.allSatisfy { $0.address == "user@example.invalid" })
  }

  @Test("focusStatus passes IMCore's string through without interpreting it")
  func focusStatusIsNotNarrowed() async throws {
    // A value no enum in this package knows. `focusStatus` returns `String` precisely so a
    // status Apple adds between releases arrives intact rather than failing to decode, and
    // that promise is only testable against a helper that can return one.
    let helper = StubHandleAvailability(focus: "com.apple.donotdisturb.mode.invented")
    let interface = HandleInterface(
      repository: try InterfaceFixtures.repository(), privateAPI: helper
    )

    let status = try await interface.focusStatus(address: "user@example.invalid")

    #expect(status == "com.apple.donotdisturb.mode.invented")
    #expect(helper.asked.map(\.question) == ["focus"])
  }

  @Test("availability refuses without a helper, and never reaches one")
  func availabilityNeedsHelper() async throws {
    let interface = HandleInterface(repository: try InterfaceFixtures.repository())

    await #expect(throws: InterfaceError.self) {
      try await interface.availability(address: "user@example.invalid", service: .iMessage)
    }
  }

  // MARK: - AttachmentInterface

  @Test("a purged attachment is recovered through the helper and its path returned")
  func purgedAttachmentIsRecovered() async throws {
    // The row's `filename` points at a path that does not exist, which is what "purged to
    // iCloud" looks like from the database's side.
    let recovered = try InterfaceFixtures.temporaryFile()
    let helper = StubAttachmentAccess(recoveredPath: recovered)
    let interface = AttachmentInterface(
      repository: try InterfaceFixtures.purgedAttachment(guid: "attachment-1"),
      privateAPI: helper
    )

    let path = try await interface.resolvePath(guid: "attachment-1")

    #expect(path == recovered)
    // Asked for the attachment the caller named: the guid is threaded through rather than
    // recomputed from the row, and a stub that ignored it would look identical without this.
    #expect(helper.requested == ["attachment-1"])
  }

  @Test("a purged attachment without a helper reports the offload, not a missing row")
  func purgedAttachmentWithoutHelper() async throws {
    let interface = AttachmentInterface(
      repository: try InterfaceFixtures.purgedAttachment(guid: "attachment-1")
    )

    // `.notFound`, but the two `.notFound`s on this path mean different things to a client:
    // "there is no such attachment" versus "it exists and is offloaded". Only the second
    // is worth offering the Private API for, so the sentence has to distinguish them.
    let error = await #expect(throws: InterfaceError.self) {
      try await interface.resolvePath(guid: "attachment-1")
    }
    #expect(error?.body.contains("offloaded to iCloud") == true)
  }

  @Test("a helper that refuses the download is an iMessage failure, not a missing attachment")
  func recoveryFailureIsTranslated() async throws {
    // The stub is arranged with no path, so it throws, standing in for iCloud declining.
    let interface = AttachmentInterface(
      repository: try InterfaceFixtures.purgedAttachment(guid: "attachment-1"),
      privateAPI: StubAttachmentAccess()
    )

    let error = await #expect(throws: InterfaceError.self) {
      try await interface.resolvePath(guid: "attachment-1")
    }
    // `.messagesFailed`, which is the 500 `iMessage Error` clients branch on: proof the
    // call went through `throughMessages`. A `.notFound` here would tell a client the
    // attachment does not exist, which is the one thing this case is not.
    #expect(error == .messagesFailed(error?.body ?? ""))
  }
}
