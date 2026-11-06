//  GenmojiSheet
//  Making a Genmoji on macOS 27 through the public Image Playground sheet, in a window nobody
//  sees.
//
//  macOS 27 withdrew the headless `ImageCreator` and left `ImagePlaygroundViewController`, the
//  sheet a person types into. Measured on 27.0.1: given its concepts and the emoji style before
//  its view loads, the sheet starts generating by itself, in a window that is never ordered on
//  screen, from an app that is never activated. What it does not do by itself is hand the
//  result back: that happens when the person confirms, which reaches the remote extension as
//  `confirmImageSelection` on the sheet's XPC connection. Sending that one message is the only
//  private step here; the glyph then arrives through the PUBLIC delegate.
//
//  Three things this file is careful about, each measured:
//
//    - **A process without a running AppKit event loop cannot host the sheet.** The headless
//      CLI has none: there the sheet never connects to its service, and the measured run
//      crashed. So `host()` refuses before any window exists, and nothing here builds one
//      unless `NSApp.isRunning`.
//    - **Confirming before the image is ready is ignored.** So the wait is a poll that sends
//      the confirmation every 1.5 seconds until the delegate has answered, rather than a guess
//      at how long generation takes (seven to ten seconds, measured).
//    - **A description Image Playground declines produces no answer at all**: no generation,
//      no delegate call, no cancel, measured with one naming a real person. Silence is the
//      only signal, so the session ends at 45 seconds, several times the measured success,
//      and says that the description was most likely declined.
//    - **The connection is found by reflection**, as `connectionManager._connection` on the
//      view controller, because nothing public exposes it. A release that renames either
//      field, or drops the message, is reported once and remembered (`broken`), so the status
//      route stops offering what the create route cannot do.
//
//  Generation is still Apple's service with Apple's own content checks: this drives the same
//  sheet the Genmoji picker in Messages uses, with a description a person typed into a client.

import AppKit
import BBCore
import Foundation
import ImageIO
import ImagePlayground
import Logging
import os

/// Whether this process can drive the Image Playground sheet.
public enum GenmojiSheetHost: Sendable, Equatable {
  /// An AppKit event loop is running and Image Playground says it is available.
  case ready
  /// No AppKit event loop: the headless server. The BlueBubbles app has one.
  case noEventLoop
  /// Image Playground itself is not available: Apple Intelligence is off or not ready.
  case imagePlaygroundUnavailable
  /// A session found the sheet's connection or its confirmation missing, with what was missing.
  case broken(String)
}

enum PlaygroundSheet {

  /// What one session hands back.
  enum Result: Sendable {
    /// The adaptive image glyph's own file: a HEIC of several strikes.
    case glyph(heic: Data)
    /// A plain image, which the emoji style is not expected to produce and is handled anyway.
    case image(Data)
    case cancelled
  }

  static let logger = Logger(label: "bluebubbles.genmoji.sheet")

  /// One sheet at a time. Two windows driving one remote extension at once is unmeasured, and
  /// each session is seconds of a model the person's own Messages may also want.
  static let turns = OneAtATime()

  /// Why the sheet cannot be driven, once a session has found out. Process-lifetime: what is
  /// missing is the system's, and does not come back without an update and a relaunch.
  static let broken = OSAllocatedUnfairLock<String?>(initialState: nil)

  /// How often the confirmation is sent, and how long the whole session may take: 45
  /// seconds, because a declined description is silent and a success takes seven to ten.
  static let confirmInterval = Duration.milliseconds(1500)
  static let confirmAttempts = 30
  /// How long a session may run without finding the sheet's connection before that is
  /// called a fault rather than a slow start. The connection was there within a second.
  static let connectionGrace = Duration.seconds(10)

  static let confirmSelector = Selector(("confirmImageSelection"))

  /// What a session that never heard back says. Image Playground does not tell the host why
  /// it declined, so this names the likely cause and what to do, without claiming either.
  static var silentSentence: String {
    "Image Playground did not make a Genmoji from that description within "
      + "\((confirmInterval * confirmAttempts).components.seconds) seconds. It declines some "
      + "descriptions without saying why, such as ones naming a real person, so try "
      + "rewording it"
  }

  @MainActor
  static func host() -> GenmojiSheetHost {
    if let reason = broken.withLock({ $0 }) { return .broken(reason) }
    // `NSApp` is nil in a process that never touched `NSApplication`, and not running in one
    // that touched it without running it. Both are the headless server.
    guard let app = NSApp, app.isRunning else { return .noEventLoop }
    guard #available(macOS 15.4, *), ImagePlaygroundViewController.isAvailable else {
      return .imagePlaygroundUnavailable
    }
    return .ready
  }

  /// One Genmoji for `description`, through a sheet that is never shown.
  @available(macOS 15.4, *)
  static func generate(description: String) async throws -> Result {
    try await turns.run { try await session(description: description) }
  }

  @available(macOS 15.4, *)
  @MainActor
  private static func session(description: String) async throws -> Result {
    // Checked again inside the turn: the host can change between the status read and here,
    // and a window built without an event loop is the crash this file exists to avoid.
    guard host() == .ready else {
      throw GenmojiGenerationError.creationFailed(
        "The Image Playground sheet cannot be hosted by this process")
    }
    let started = ContinuousClock.now
    let session = Session(description: description)
    defer { session.close() }

    let result = try await poll(.every(confirmInterval, attempts: confirmAttempts)) { _ in
      if let result = session.result { return result }
      try session.confirm(since: started)
      return nil
    }
    guard let result else {
      throw GenmojiGenerationError.noAnswer(Self.silentSentence)
    }
    logger.debug(
      "Image Playground sheet session finished",
      metadata: [
        "ms": .stringConvertible((ContinuousClock.now - started).components.seconds * 1000),
        "kind": .string(result.kind),
      ])
    return result
  }

  /// Records why the sheet cannot be driven, once, so the status route says so from now on.
  static func markBroken(_ reason: String) {
    let first = broken.withLock { current -> Bool in
      guard current == nil else { return false }
      current = reason
      return true
    }
    if first {
      logger.info(
        "The Image Playground sheet cannot be driven on this macOS",
        metadata: ["reason": .string(reason)])
    }
  }

  // MARK: - One session

  @available(macOS 15.4, *)
  @MainActor
  final class Session: NSObject, ImagePlaygroundViewController.Delegate {
    private let window: NSWindow
    private let controller: ImagePlaygroundViewController
    private(set) var result: Result?

    init(description: String) {
      controller = ImagePlaygroundViewController()
      // The configuration that was measured: an ordinary titled window that is never
      // ordered on screen, never key, and excluded from the Window menu.
      window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 760),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
      super.init()
      window.isReleasedWhenClosed = false
      window.isExcludedFromWindowsMenu = true
      controller.delegate = self
      controller.concepts = [.text(description)]
      controller.allowedGenerationStyles = [.emoji]
      controller.selectedGenerationStyle = .emoji
      // Assigning the controller loads its view, which is what starts the remote extension
      // generating. The window is never shown.
      window.contentViewController = controller
    }

    /// Sends the confirmation the person would, once the connection exists.
    ///
    /// Throws when the sheet is structurally unable to answer: no connection after the
    /// grace period, or a connection that does not take the message. Both are remembered.
    func confirm(since started: ContinuousClock.Instant) throws {
      guard let connection = Self.connection(of: controller) else {
        guard ContinuousClock.now - started > PlaygroundSheet.connectionGrace else { return }
        let reason = "the sheet never connected to Image Playground's service"
        PlaygroundSheet.markBroken(reason)
        throw GenmojiGenerationError.creationFailed(
          "Image Playground could not be reached: \(reason)")
      }
      // Errors from the remote side are reported by the poll running out, which says more
      // than an XPC error code would; the handler only has to exist.
      let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as AnyObject
      guard proxy.responds(to: PlaygroundSheet.confirmSelector) else {
        let reason = "the sheet no longer accepts a confirmation"
        PlaygroundSheet.markBroken(reason)
        throw GenmojiGenerationError.creationFailed(
          "Image Playground could not be driven: \(reason)")
      }
      _ = proxy.perform(PlaygroundSheet.confirmSelector)
    }

    func close() {
      controller.delegate = nil
      window.contentViewController = nil
      window.close()
    }

    /// The sheet's XPC connection: `connectionManager._connection` today, and any connection
    /// one level below the manager if a release renames the second field.
    static func connection(of controller: ImagePlaygroundViewController) -> NSXPCConnection? {
      guard let manager = child(named: "connectionManager", of: controller) else { return nil }
      if let named = child(named: "_connection", of: manager) as? NSXPCConnection {
        return named
      }
      for child in Mirror(reflecting: manager).children {
        if let connection = unwrapped(child.value) as? NSXPCConnection { return connection }
      }
      return nil
    }

    private static func child(named label: String, of subject: Any) -> Any? {
      Mirror(reflecting: subject).children.first { $0.label == label }.flatMap {
        unwrapped($0.value)
      }
    }

    /// The value inside an Optional, or the value itself; nil for an Optional that is empty.
    private static func unwrapped(_ value: Any) -> Any? {
      let mirror = Mirror(reflecting: value)
      guard mirror.displayStyle == .optional else { return value }
      return mirror.children.first?.value
    }

    // MARK: Delegate

    func imagePlaygroundViewController(
      _ imagePlaygroundViewController: ImagePlaygroundViewController,
      didCreate adaptiveImageGlyph: NSAdaptiveImageGlyph
    ) {
      result = result ?? .glyph(heic: adaptiveImageGlyph.imageContent)
    }

    func imagePlaygroundViewController(
      _ imagePlaygroundViewController: ImagePlaygroundViewController,
      didCreateImageAt imageURL: URL
    ) {
      // Reported rather than dropped when unreadable: the poll would otherwise run out and
      // blame Image Playground for a file this process could not open.
      guard result == nil else { return }
      result = (try? Data(contentsOf: imageURL)).map(Result.image) ?? .cancelled
    }

    func imagePlaygroundViewControllerDidCancel(
      _ imagePlaygroundViewController: ImagePlaygroundViewController
    ) {
      result = result ?? .cancelled
    }
  }
}

extension PlaygroundSheet.Result {
  /// For the log line: which kind of answer, never its content.
  var kind: String {
    switch self {
    case .glyph: "glyph"
    case .image: "image"
    case .cancelled: "cancelled"
    }
  }
}
