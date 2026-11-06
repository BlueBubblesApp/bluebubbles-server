//  OwnedTaskPolicyTests
//  A long-running task with an owner is an `OwnedTask`, everywhere, and a service's stop and
//  an app model's detach wait for the ones they hold.
//
//  The first rule used to be scanned under `Composition/Services` alone, and the bare tasks it
//  exists to stop were in the rest of the tree: a settings pump whose `isRunning` stayed true
//  after its stream ended, a reconnect loop whose `defer` cleared the handle of the loop
//  started after it, a monitor that kept ticking against a released owner. So the scan is the
//  whole of `Sources/` and `Helper/`, and a file that keeps a bare `Task` says why below.
//
//  What is matched is a STORED `Task<Void, …>` declared at member depth. A task that produces
//  a value (`Task<AccessToken, …>`) is a computation callers join, not a loop somebody owns;
//  a local `let task = Task {…}` awaited in the same function is not held at all.
//
//  The exemptions share one shape, and it is the one `OwnedTask` cannot express: a task
//  started on demand whose handle is cleared ON THE ACTOR at the moment its body decides it
//  is done, so the next piece of work arriving a moment later starts a new one. `OwnedTask`
//  clears its handle only once the body has returned and left the actor, and work arriving in
//  that gap finds a task apparently running and starts nothing.

import BBTestCore
import Foundation
import Testing

@Suite("Owned tasks")
struct OwnedTaskPolicyTests {

  static let ownedTasks = PolicyRule(
    rule: "A long-running task something owns is an `OwnedTask`, never a stored bare `Task`.",
    fix: "Hold an `OwnedTask` (BBCore/OwnedTask.swift) instead, or list the file in "
      + "`bareTaskAllowed` with the reason it cannot.",
    home: #"CLAUDE.md, "Never hand-roll a timeout""#)

  static let serviceStops = PolicyRule(
    rule: "A service's `stop()` awaits the `stop()` of each `OwnedTask` it holds, so a stop that "
      + "returns has nothing of the service still running.",
    fix: "Replace the `cancel()` with `await task.stop()`.",
    home: #"CLAUDE.md, "Never hand-roll a timeout""#)

  static let detachStops = PolicyRule(
    rule: "An app model's `detach()` awaits the `stop()` of each `OwnedTask` it holds, so nothing "
      + "it followed writes after it has cleared.",
    fix: "Make `detach` `async` and replace the `cancel()` with `await task.stop()`.",
    home: #"CLAUDE.md, "Never hand-roll a timeout""#)

  /// Files that keep a bare stored `Task`, and why. Paths are relative to the repository.
  private static let bareTaskAllowed: [String: String] = [
    "Sources/BBAudit/AuditRecorder.swift":
      "the flush stays registered until its write has finished and schedules the next from "
      + "inside it; the summary timer is re-armed from inside its own body",
    "Sources/BBAudit/Syslog/SyslogForwarder.swift":
      "the sender is started per record and cleared on the actor as it finds the queue empty",
    "Sources/BBAuth/AccessControlPersistence.swift":
      "the writer and the failure debounce are started on demand and cleared on the actor",
    "Sources/BBProxy/Tunnels.swift":
      "the reconnect is started per exit and cleared on the actor as it returns",
    "Sources/BlueBubblesServerCore/Composition/HTTPListener.swift":
      "the exit handler runs inside the body and must clear the handle before it reports",
    "Sources/BlueBubblesApp/AppModel.swift":
      "the start attempt clears itself on the main actor, so a retry is accepted at once",
    "Sources/BlueBubblesApp/FirebaseSetupModel.swift":
      "the operation clears itself on the main actor, so the next press is accepted at once",
  ]

  @Test("No stored bare Task outside the files that say why")
  func storedTasksAreOwned() throws {
    let files = try SourceScanner.swiftFiles(under: "Sources", "Helper", minimum: 100)
      .filter { Self.bareTaskAllowed[$0.path] == nil }
    // Member depth is two spaces in this tree. A nested type's members are deeper, and so is
    // every local.
    let stored = try Regex(
      #"^  (@\w+ )*((private|fileprivate|internal|public|nonisolated)(\(set\))? )*(var|let) \w+: Task<Void,"#
    )
    let offences = SourceScanner.offences(in: files) { _, line in
      line.code.contains(stored)
    }
    #expect(offences.isEmpty, Self.ownedTasks.comment(offences))
  }

  @Test("Every exemption still names a file that holds a bare Task")
  func exemptionsAreCurrent() throws {
    for path in Self.bareTaskAllowed.keys {
      let file = try SourceScanner.file(path)
      #expect(
        file.code.contains("Task<Void,"),
        "\(path) no longer holds a bare Task; remove its exemption")
    }
  }

  /// A service's `stop()` that only CANCELS returns while the old body still runs, so a
  /// restart puts the next instance beside it: a scheduled message read by the old sweep was
  /// sent after it had been cancelled. `OwnedTask.stop()` cancels and waits.
  @Test("A service stops its owned tasks rather than cancelling them")
  func serviceStopsWait() throws {
    let offences = try Self.cancellations(
      under: "Sources/BlueBubblesServerCore/Composition/Services", minimum: 10,
      inside: "func stop() async {")
    #expect(offences.isEmpty, Self.serviceStops.comment(offences))
  }

  /// The app's half of the same rule. A child model follows the server on an `OwnedTask` and
  /// clears what it held in `detach`; a follow cancelled while suspended in its seed resumes
  /// and writes, so a `detach` that only cancels lets a stopped server's state land after
  /// the clear. `AppModel`'s own follows are held to it by `FollowTable.stopAll`.
  @Test("A child model's detach stops its owned tasks rather than cancelling them")
  func childModelDetachWaits() throws {
    let offences = try Self.cancellations(
      under: "Sources/BlueBubblesApp/Models", minimum: 10, inside: "func detach(")
    #expect(offences.isEmpty, Self.detachStops.comment(offences))
  }

  /// Every `<name>.cancel()` on an `OwnedTask` the same file declares, inside the body of a
  /// function whose declaration line contains `declaration`.
  private static func cancellations(
    under directory: String, minimum: Int, inside declaration: String
  ) throws -> [Offence] {
    let files = try SourceScanner.swiftFiles(under: directory, minimum: minimum)
    let owned = try Regex(#"let (\w+) = OwnedTask\(\)"#, as: (Substring, Substring).self)
    var offences: [Offence] = []
    for file in files {
      let lines = file.lines
      let names = Set(
        lines.compactMap { line in line.code.firstMatch(of: owned).map { String($0.1) } })
      guard !names.isEmpty else { continue }
      for (index, line) in lines.enumerated() where line.code.contains(declaration) {
        var depth = 0
        for body in lines[index...] {
          depth += body.code.filter { $0 == "{" }.count - body.code.filter { $0 == "}" }.count
          if names.contains(where: { body.code.contains("\($0).cancel()") }) {
            offences.append(Offence(file, body))
          }
          if depth == 0 { break }
        }
      }
    }
    return offences
  }
}
