//  AllocationPolicyTests
//  The helper allocates through one door, and the door initialises too.
//
//  `+alloc` returns an object at +1 and `-init…` CONSUMES that +1. Both halves have now been
//  got wrong here, in opposite directions, and each cost something:
//
//    - `perform(alloc)?.takeUnretainedValue()` left the +1 unconsumed and let ARC add a
//      retain of its own: one permanently over-retained IMCore object per message, tapback,
//      sticker, attachment and poll sent, accumulating in the USER'S MESSAGES;
//    - fixing that by handing the allocation to Swift and initialising it in a SECOND call
//      left Swift holding a managed reference to an object `init` had already disposed of.
//      `POST /api/v1/message/attachment` hit it on every send and killed Messages with
//      `EXC_ARM_PAC_FAIL` inside `swift_unknownObjectRelease`.
//
//  So the door is `IMCoreRuntime.create(_:_:_:)`, which delegates to
//  `BBAllocateAndInitialize` in the Objective-C shim: allocation and initialiser in one
//  operation, in a file the compiler compiles with ARC, with the uninitialised object never
//  crossing into Swift at all. The rule is not "remember the convention"; it is "the
//  convention is not expressible from here".
//
//  It was nine sites for the first mistake and thirteen for the second, because the pattern
//  gets copied rather than reasoned about each time. Hence a scan rather than a comment.

import Foundation
import Testing

@Suite("Allocation policy")
struct AllocationPolicyTests {

  /// The helper tree, located from this file so the scan cannot silently cover nothing.
  private static func helperSources() throws -> [(label: String, source: String)] {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Helper")

    guard let files = FileManager.default.enumerator(atPath: root.path) else { return [] }
    var sources: [(String, String)] = []
    for case let relative as String in files where relative.hasSuffix(".swift") {
      let text = try String(contentsOf: root.appending(path: relative), encoding: .utf8)
      sources.append((relative, text))
    }
    return sources
  }

  @Test("No Swift file in the helper allocates through perform")
  func allocationGoesThroughTheGateway() throws {
    let sources = try Self.helperSources()
    #expect(sources.count > 10, "the scan found \(sources.count) files, which cannot be right")

    var offenders: [String] = []
    for (label, source) in sources {
      for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        let code = line.trimmingCharacters(in: .whitespaces)
        if code.hasPrefix("//") { continue }
        // `responds(to: NSSelectorFromString("alloc"))` is a capability CHECK, not an
        // allocation, and is allowed: it asks whether a class can allocate without doing it.
        if code.contains("responds(to:") { continue }
        // Three spellings, not one. The scan matched only the literal
        // `NSSelectorFromString("alloc")`, and three live sites named the selector as a
        // STRING ARGUMENT to the gateway instead — `IMCoreRuntime.send(type, "alloc")` and
        // `IMCoreRuntime.invoke(type, "alloc", [])`. Both end in a take that does not
        // consume the +1, so they are the same defect this suite exists for, wearing a
        // different spelling, and it passed while they sat in the tree.
        //
        // The other three ownership-transferring selectors are matched too: `+new`,
        // `-copy` and `-mutableCopy` all return +1 and none of them has ever been used
        // here, which is the moment to say so rather than after the first one appears.
        let ownershipTransferring = ["alloc", "new", "copy", "mutableCopy"]
        let names = ownershipTransferring.map { "\"\($0)\"" }
        let namesASelector = names.contains { code.contains("NSSelectorFromString(\($0))") }
        let passesASelectorName =
          (code.contains("IMCoreRuntime.send(") || code.contains("IMCoreRuntime.invoke("))
          && names.contains { code.contains($0) }
        guard namesASelector || passesASelectorName else { continue }
        offenders.append("\(label):\(index + 1): \(code)")
      }
    }

    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "construct through `IMCoreRuntime.create`, which owns the +1 correctly:\n"
          + offenders.joined(separator: "\n"))
    )
  }

  @Test("An alloc result is never taken unretained")
  func allocIsNeverTakenUnretained() throws {
    // The specific spelling that caused it, checked across the two lines it spanned: the
    // `perform` and the `takeUnretainedValue()` sat on separate lines at every site.
    for (label, source) in try Self.helperSources() {
      let collapsed = source.replacingOccurrences(of: "\n", with: " ")
      let hasAllocPerform =
        collapsed.contains(#"perform(NSSelectorFromString("alloc"))"#)
        || collapsed.contains(#"perform(NSSelectorFromString( "alloc" ))"#)
      #expect(!hasAllocPerform, "\(label) performs +alloc directly")
    }
  }

  @Test("The gateway is what the helper calls")
  func gatewayIsUsed() throws {
    // The other half: a scan that only forbids can be satisfied by removing the feature.
    let uses = try Self.helperSources().filter { $0.source.contains("IMCoreRuntime.create(") }
    #expect(
      uses.count >= 5,
      "expected the allocation gateway to be used across the helper, found \(uses.count)"
    )
  }

  /// The second mistake, which the first fix introduced: an allocation that reaches Swift
  /// and is initialised separately. `create` is the only way to construct an IMCore object,
  /// so nothing may name a vended allocator, and no `init…` selector may travel through the
  /// general call paths — those hand back the receiver's +1 to nobody.
  @Test("An allocation is never separated from its initialiser")
  func allocationAndInitialisationAreOneCall() throws {
    var offenders: [String] = []
    for (label, source) in try Self.helperSources() {
      for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        let code = line.trimmingCharacters(in: .whitespaces)
        if code.hasPrefix("//") || code.hasPrefix("///") { continue }
        // A vended allocator: `create` replaced it, and nothing may bring one back.
        if code.contains("IMCoreRuntime.allocate(") {
          offenders.append("\(label):\(index + 1): \(code)")
          continue
        }
        // An initialiser sent through a path that does not know the convention. Matched on
        // the selector STRING, which is how every one of these is written.
        let initialiserSent =
          (code.contains("IMCoreRuntime.invoke(") || code.contains("IMCoreRuntime.send(")
            || code.contains("IMCoreRuntime.initWith"))
          && (code.contains("\"init") || code.contains("+ \"init"))
        if initialiserSent {
          offenders.append("\(label):\(index + 1): \(code)")
        }
      }
    }

    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "construct through `IMCoreRuntime.create`, which owns both halves:\n"
          + offenders.joined(separator: "\n"))
    )
  }
}
