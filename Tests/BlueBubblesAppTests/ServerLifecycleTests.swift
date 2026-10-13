//  ServerLifecycleTests
//  The two lists that undo a start: what was attached, and what is being followed.
//
//  Neither can be exercised through `AppModel.start` in a test process, which opens two
//  databases and binds a port. Both are types of their own for that reason, and these pin
//  the properties `AppModel` relies on: every attach is undone, in reverse, exactly once; and
//  stopping the follows clears what they held while cancelling one keeps it.
//
//  `FrontEndPlumbingPolicyTests` holds the other half: that `AppModel` attaches every child
//  through the list and detaches none by hand.

import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Server lifecycle")
@MainActor
struct ServerLifecycleTests {

  /// A child that records when it was detached.
  private final class Child: ServerAttachable {
    let name: String
    let log: Log
    init(_ name: String, log: Log) {
      self.name = name
      self.log = log
    }
    func detach() async { log.events.append(name) }
  }

  private final class Log {
    var events: [String] = []
  }

  private struct Refused: Error {}

  @Test("Detaching undoes every attach, the most recent first, and only once")
  func detachesInReverseOnce() async {
    let log = Log()
    let attachments = ServerAttachments()
    await attachments.attach(Child("storage", log: log)) { _ in }
    attachments.onDetach("server") { log.events.append("server") }
    await attachments.attach(Child("alerts", log: log)) { _ in }

    await attachments.detachAll()
    #expect(log.events == ["alerts", "server", "storage"])
    #expect(attachments.names.isEmpty)

    // A second teardown (a stop after a failed start, say) finds nothing to repeat.
    await attachments.detachAll()
    #expect(log.events == ["alerts", "server", "storage"])
  }

  @Test("A child whose attach threw is not detached; everything before it is")
  func failedAttachIsNotRecorded() async {
    let log = Log()
    let attachments = ServerAttachments()
    await attachments.attach(Child("storage", log: log)) { _ in }
    await #expect(throws: Refused.self) {
      try await attachments.attach(Child("broken", log: log)) { _ in throw Refused() }
    }

    await attachments.detachAll()
    #expect(log.events == ["storage"])
  }

  @Test("Stopping the follows clears what they held; cancelling one keeps it")
  func stopClearsCancelKeeps() async {
    let table = FollowTable()
    var cleared: [ServerFollow] = []
    table.start(.privateAPIRuntime, reset: { cleared.append(.privateAPIRuntime) }, Task {})
    table.start(.accessControl, reset: { cleared.append(.accessControl) }, Task {})

    // The runtime follow is cancelled whenever it is pointed at another runtime, and what it
    // held is kept until the next one replaces it.
    table.cancel(.privateAPIRuntime)
    #expect(cleared.isEmpty)
    #expect(table.following == [.accessControl])

    table.stopAll()
    #expect(Set(cleared) == [.privateAPIRuntime, .accessControl])
    #expect(table.following.isEmpty)
  }

  @Test("Starting a follow again replaces it, and keeps its reset unless given another")
  func restartReplaces() async {
    let table = FollowTable()
    var cleared = 0
    let first = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
    table.start(.tools, reset: { cleared += 1 }, first)
    table.start(.tools, reset: nil, Task {})

    #expect(first.isCancelled)
    table.stopAll()
    #expect(cleared == 1)
  }

  @Test("A model with no server follows nothing and stopping it is harmless")
  func stoppingAnIdleModel() async {
    let model = AppModel()
    #expect(model.follows.following.isEmpty)
    #expect(model.attachments.names.isEmpty)
    model.stopFollowingServer()
    await model.stop()
    #expect(model.phase == .idle)
  }
}
