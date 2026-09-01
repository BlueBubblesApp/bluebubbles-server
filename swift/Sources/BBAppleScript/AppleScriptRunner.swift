//  AppleScriptRunner
//  Compiled AppleScript with typed parameters.
//
//  What this replaces
//  ------------------
//  The current server shells out: `osascript -e "line" -e "line"`, with the message text
//  interpolated into the source. That forces `escapeOsaExp`, which escapes for TWO layers at
//  once — the shell and the AppleScript parser — and reads like this:
//
//      .replace(/\\/g, "\\\\\\\\")   // backslash becomes FOUR backslashes
//      .replace(/"/g, '\\\\"')
//
//  Every send re-parses the script, spawns a process, and depends on that escaping being
//  exactly right for arbitrary user text. A quote in a message is a broken send at best.
//
//  Here the script is compiled ONCE and values are passed as Apple Event parameters to a
//  handler. There is no string interpolation, so there is no escaping layer and no injection
//  surface: a message containing quotes, backslashes or newlines is just a string parameter.
//
//  Threading: this runs on the MAIN thread, and it has to
//  ---------------------------------------------------
//  `NSAppleScript` is not thread-safe, but that is the smaller half. AppleScript's remote
//  send does not wait on the Foundation run loop — a stack sample of a hung call shows it
//  inside the Carbon event loop:
//
//      UASRemoteSend -> InternalComponentActive -> AEDefaultActiveProc
//        -> WNEInternal -> GetNextEventMatchingMask -> RunCurrentEventLoopInMode -> mach_msg
//
//  That reply is delivered through the process's main event loop. Executing on a private
//  run-loop thread compiles, looks reasonable, and blocks forever; it was tried.
//
//  So work is posted to the main thread with `waitUntilDone: false` and bridged back with
//  `withCheckedContinuation`. Two consequences worth stating plainly:
//
//    - **The caller suspends, it does not block.** Blocking with `waitUntilDone: true` from
//      an async context parks a Swift-concurrency cooperative thread for the whole send —
//      seconds, on a real one — and deadlocked outright under a parallel test runner.
//    - **The host must pump a main run loop.** An AppKit/SwiftUI app does this by definition.
//      A plain executable must run one itself; see Tools/send-probe. The `swift test` bundle
//      host does NOT, which is why the end-to-end check is an executable rather than a test.
//
//  See `.claude/docs/imessage.md`.

import BBCore
import Carbon
import Foundation
import Logging

public enum AppleScriptError: BBError, Equatable {
  case compilationFailed(message: String)
  /// The script ran and raised. `number` is the AppleScript error number, which is the part
  /// worth branching on — -1743 is "not permitted", -600 is "application isn't running".
  case executionFailed(number: Int, message: String)
  /// Automation permission for the target application has not been granted.
  case notPermitted(target: String)
  case targetNotRunning(target: String)

  /// AppleScript error numbers that mean something specific enough to act on.
  static func mapped(number: Int, message: String, target: String) -> AppleScriptError {
    switch number {
    case -1743, -10004: .notPermitted(target: target)
    case -600, -609: .targetNotRunning(target: target)
    default: .executionFailed(number: number, message: message)
    }
  }
}

/// A value that can cross into AppleScript as a handler parameter.
public enum AppleScriptValue: Sendable, Equatable {
  case string(String)
  case integer(Int)
  case boolean(Bool)
  /// A filesystem path, delivered as an alias-resolvable POSIX path string. The script side
  /// applies `as POSIX file`, because doing so here would fail for a file that does not
  /// exist yet.
  case path(String)
  case list([AppleScriptValue])

  var descriptor: NSAppleEventDescriptor {
    switch self {
    case .string(let value), .path(let value):
      NSAppleEventDescriptor(string: value)
    case .integer(let value):
      NSAppleEventDescriptor(int32: Int32(clamping: value))
    case .boolean(let value):
      NSAppleEventDescriptor(boolean: value)
    case .list(let values):
      {
        let list = NSAppleEventDescriptor.list()
        // AppleEvent lists are 1-indexed, and `insert(at: 0)` appends.
        for value in values { list.insert(value.descriptor, at: 0) }
        return list
      }()
    }
  }
}

// MARK: - The dedicated execution thread

/// What one execution needs. Sendable so it can cross to the script thread.
struct ScriptRequest: Sendable {
  let key: String
  let source: String
  let handler: String
  let arguments: [AppleScriptValue]
  let target: String
}

/// One thread with a run loop, owning every compiled script.
///
/// `@unchecked Sendable`: all mutable state is touched only on `thread`, which is the
/// invariant this type exists to provide. The compiler cannot see that, so it is asserted
/// here and kept honest by making the type private and never handing out an `NSAppleScript`.
///
/// Two things about the threading are load-bearing, and both were learned the hard way:
///
/// 1. **A dedicated run-loop thread, scheduled via `perform(_:on:with:waitUntilDone:)`.**
///    `NSAppleScript` is not thread-safe, and `executeAppleEvent` pumps a run loop while it
///    waits for the target application's reply. Hand-rolling this with `CFRunLoopPerformBlock`
///    deadlocks when the block is posted in a mode the loop is not running.
///
/// 2. **Never `waitUntilDone: true` from an async caller.** That blocks the calling thread,
///    and when the caller is a Swift concurrency task the blocked thread belongs to the
///    cooperative pool. A real send holds it for a second or more; under a parallel test
///    runner it deadlocked outright. Completion is delivered by callback and bridged with
///    `withCheckedContinuation`, so the caller suspends instead of blocking.
private final class ScriptExecutor: NSObject, @unchecked Sendable {

  static let shared = ScriptExecutor()

  /// Touched only on the main thread.
  ///
  /// Read and written through `cachedScript`/`cache` — never handed to a callee as
  /// `inout`. See `invoke(_:)`.
  private var compiled: [String: NSAppleScript] = [:]

  private override init() { super.init() }

  /// Runs a request on the script thread and calls back when it finishes. Never blocks the
  /// caller.
  func execute(
    _ request: ScriptRequest,
    completion: @escaping @Sendable (Result<String?, AppleScriptError>) -> Void
  ) {
    let box = WorkBox(request: request, completion: completion)
    perform(#selector(invoke(_:)), on: .main, with: box, waitUntilDone: false)
  }

  /// Runs one queued request.
  ///
  /// **This must not hold exclusive access to `compiled` while the script runs.**
  ///
  /// `NSAppleScript.executeAppleEvent` pumps a nested run loop while it waits for the
  /// target application to reply, and that nested loop dispatches the NEXT queued
  /// `invoke(_:)` on this same thread. Passing `&compiled` into the executor takes
  /// exclusive access for the whole call, so the re-entrant invocation takes it again and
  /// the Swift runtime traps: "Simultaneous accesses ... but modification requires
  /// exclusive access". That is a hard crash of the server, and it fires as soon as two
  /// AppleScripts are queued close together — which is the ordinary case for a non-SIP
  /// user sending messages, the configuration this path exists to serve.
  ///
  /// So the cache is touched in two SHORT accesses either side of the run instead, and the
  /// script itself is held as a local. Re-entrancy is then harmless: the inner call reads
  /// and writes the dictionary while the outer one is holding nothing.
  @objc private func invoke(_ box: WorkBox) {
    box.completion(
      AppleScriptRunner.execute(
        box.request,
        cachedScript: { [weak self] key in self?.compiled[key] },
        store: { [weak self] key, script in self?.compiled[key] = script }
      )
    )
  }

  private final class WorkBox: NSObject, @unchecked Sendable {
    let request: ScriptRequest
    let completion: @Sendable (Result<String?, AppleScriptError>) -> Void
    init(
      request: ScriptRequest,
      completion: @escaping @Sendable (Result<String?, AppleScriptError>) -> Void
    ) {
      self.request = request
      self.completion = completion
    }
  }
}

// MARK: - Public interface

/// Compiles scripts once and runs their handlers.
/// The AppleScript boundary.
///
/// A protocol for the same reason `ProcessRunning`, `PermissionProbing`, `HTTPPerforming`,
/// `AlertStoring` and `AccessControlPersistence` are: it is where this server stops and
/// something outside it begins. AppleScript was the only such boundary without one.
///
/// `AppleScriptMessageSender` already took its runner as a parameter — but a CONCRETE one,
/// so the only paths a test could reach were the validations that run BEFORE the script
/// does. What a `-1743` becomes, whether a failure is worth retrying under a different
/// spelling of the chat GUID, and what a caller is told when no spelling works were all
/// unreachable. Those are the paths a user actually meets.
public protocol AppleScriptRunning: Sendable {
  func run(
    key: String,
    source: String,
    handler: String,
    arguments: [AppleScriptValue],
    target: String
  ) async throws -> String?
}

extension AppleScriptRunner: AppleScriptRunning {}

public actor AppleScriptRunner {

  private let logger: Logger

  public init(logger: Logger = Logger(label: "bluebubbles.applescript")) {
    self.logger = logger
  }

  /// Compiles a script if it is not already compiled, then calls one of its handlers.
  ///
  /// - Parameters:
  ///   - key: Cache key. Compilation is the expensive part, so it happens once per key.
  ///   - source: The script source. Contains handlers only — never interpolated values.
  ///   - handler: The handler to call. AppleScript lowercases handler names internally.
  ///   - arguments: Positional parameters, passed as Apple Event descriptors.
  ///   - target: Named only for error reporting, so "not permitted" says what it wanted.
  @discardableResult
  public func run(
    key: String,
    source: String,
    handler: String,
    arguments: [AppleScriptValue] = [],
    target: String = "Messages"
  ) async throws -> String? {
    let request = ScriptRequest(
      key: key, source: source, handler: handler, arguments: arguments, target: target
    )
    let outcome = await withCheckedContinuation { continuation in
      ScriptExecutor.shared.execute(request) { continuation.resume(returning: $0) }
    }

    switch outcome {
    case .success(let value):
      return value
    case .failure(let error):
      logger.debug(
        "AppleScript failed",
        metadata: [
          "handler": .string(handler),
          "error": .string(String(describing: error)),
        ])
      throw error
    }
  }

  /// Everything below runs on the script thread.
  /// - Parameters:
  ///   - cachedScript: Looks up an already-compiled script. A closure rather than an
  ///     `inout` dictionary so the caller's access ENDS before the script runs — see
  ///     `ScriptExecutor.invoke(_:)` for why holding it across execution crashes.
  ///   - store: Records a newly compiled script, in an equally short access.
  static func execute(
    _ request: ScriptRequest,
    cachedScript: (String) -> NSAppleScript?,
    store: (String, NSAppleScript) -> Void
  ) -> Result<String?, AppleScriptError> {
    let (key, source, handler) = (request.key, request.source, request.handler)
    let (arguments, target) = (request.arguments, request.target)
    var errorInfo: NSDictionary?

    let script: NSAppleScript
    if let existing = cachedScript(key) {
      script = existing
    } else {
      guard let created = NSAppleScript(source: source) else {
        return .failure(.compilationFailed(message: "NSAppleScript refused the source"))
      }
      guard created.compileAndReturnError(&errorInfo) else {
        return .failure(.compilationFailed(message: Self.message(from: errorInfo)))
      }
      // Stored BEFORE the run, so a re-entrant invocation of the same script reuses
      // this compilation rather than compiling a second copy.
      store(key, created)
      script = created
    }

    // Address the event at ourselves: the handler lives in OUR script, and it is the
    // `tell application "Messages"` inside it that crosses the process boundary.
    var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
    guard
      let selfTarget = NSAppleEventDescriptor(
        descriptorType: typeProcessSerialNumber,
        bytes: &psn,
        length: MemoryLayout<ProcessSerialNumber>.size
      )
    else {
      return .failure(.executionFailed(number: 0, message: "could not address the current process"))
    }

    let event = NSAppleEventDescriptor(
      eventClass: AEEventClass(kASAppleScriptSuite),
      eventID: AEEventID(kASSubroutineEvent),
      targetDescriptor: selfTarget,
      returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID)
    )
    event.setParam(
      NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(keyASSubroutineName)
    )
    if !arguments.isEmpty {
      event.setParam(
        AppleScriptValue.list(arguments).descriptor, forKeyword: AEKeyword(keyDirectObject)
      )
    }

    let result = script.executeAppleEvent(event, error: &errorInfo)
    if let errorInfo {
      let number = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
      return .failure(
        .mapped(number: number, message: Self.message(from: errorInfo), target: target)
      )
    }
    return .success(result.stringValue)
  }

  private static func message(from info: NSDictionary?) -> String {
    (info?[NSAppleScript.errorMessage] as? String) ?? "unknown AppleScript error"
  }
}

extension AppleScriptError {
  public var code: String {
    switch self {
    case .compilationFailed: "applescript.compilation_failed"
    case .executionFailed: "applescript.execution_failed"
    case .notPermitted: "applescript.not_permitted"
    case .targetNotRunning: "applescript.target_not_running"
    }
  }

  public var domain: String { "Messaging" }

  public var isUserFacing: Bool {
    switch self {
    case .notPermitted, .targetNotRunning: true
    default: false
    }
  }

  public var title: String { "An AppleScript could not run" }

  public var body: String {
    switch self {
    case .compilationFailed(let message): message
    case .executionFailed(let number, let message): "\(message) (error \(number))"
    case .notPermitted(let target):
      "This server is not permitted to control \(target). Grant it under Privacy & Security → Automation."
    case .targetNotRunning(let target): "\(target) is not running."
    }
  }
}
