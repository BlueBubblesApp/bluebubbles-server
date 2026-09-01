//  ObservationProbe
//  A read-only instrument for the event-observation ladder investigation.
//
//  This is NOT part of the server. It is a throwaway dylib you inject into Messages.app to
//  answer one question empirically: for each inbound event we need, what is the HIGHEST rung
//  of the ladder that actually works on this macOS version?
//
//      Rung 1  Observe an IMCore-posted NSNotification
//      Rung 2  Register as an additional IMDaemonListener / delegate
//      Rung 3  Swizzle a message-layer method       (what ships today)
//      Rung 4  Swizzle a UI-layer method            (a defect, not a solution)
//
//  It answers that by OBSERVING ONLY. It installs no swizzles, mutates nothing, and sends
//  nothing. Every lookup goes through NSClassFromString / NSSelectorFromString with a
//  respondsToSelector guard, so a class or selector that has moved produces a log line rather
//  than taking the user's Messages.app down with it.
//
//  Results go to ~/Library/Logs/bluebubbles-server/observation-probe.log and to os_log under
//  the subsystem com.bluebubbles.probe.
//
//  See docs/OBSERVATION_LADDER.md for how to run it and how to read what comes out.

import Foundation
import os

// MARK: - Output

/// Writes to a file and to os_log.
///
/// The file matters more than it looks: `log stream` output is easy to lose, and the useful
/// artifact from a probe run is a diffable text file you can attach to an issue.
final class ProbeLog: @unchecked Sendable {

    static let shared = ProbeLog()

    private let logger = Logger(subsystem: "com.bluebubbles.probe", category: "observation")
    private let handle: FileHandle?
    private let lock = NSLock()

    /// The path this actually resolved to, which is NOT the path you would guess.
    ///
    /// Messages.app is sandboxed, so `NSHomeDirectory()` — and therefore
    /// `expandingTildeInPath` — returns its container, not the user's home. The log lands in
    /// ~/Library/Containers/com.apple.MobileSMS/Data/Library/Logs/bluebubbles-server.
    /// Writing to the real home instead is not an option: the sandbox denies it. So the
    /// probe records where it ended up and `run-probe.sh --log` prints the same path.
    let path: String

    private init() {
        let directory = ("~/Library/Logs/bluebubbles-server" as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        path = directory + "/observation-probe.log"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
    }

    func write(_ message: String) {
        logger.info("\(message, privacy: .public)")

        lock.lock()
        defer { lock.unlock() }
        let stamp = ISO8601DateFormatter().string(from: Date())
        handle?.write(Data("\(stamp)  \(message)\n".utf8))
    }

    func section(_ title: String) {
        write("")
        write("=== \(title) ===")
    }
}

// MARK: - Runtime helpers

/// Whether this process is sandboxed.
///
/// Detected by asking where home is: Foundation returns the container for a sandboxed
/// process while the HOME environment variable still holds the real one. Checking for the
/// entitlement would need a SecCode round-trip for a fact this comparison already settles.
enum Sandbox {
    static let isSandboxed: Bool = NSHomeDirectory().contains("/Library/Containers/")
}

enum Runtime {

    static func objcClass(_ name: String) -> AnyClass? {
        NSClassFromString(name)
    }

    static func responds(_ object: AnyObject, to selectorName: String) -> Bool {
        object.responds(to: NSSelectorFromString(selectorName))
    }

    static func classResponds(_ name: String, to selectorName: String) -> Bool {
        guard let cls = objcClass(name) else { return false }
        return class_getInstanceMethod(cls, NSSelectorFromString(selectorName)) != nil
    }

    /// Calls a zero-argument selector, guarded.
    ///
    /// `perform` is unmanaged and can crash on an unexpected return type, so this is used
    /// ONLY for known-object-returning accessors like `sharedInstance`.
    static func call(_ object: AnyObject, _ selectorName: String) -> AnyObject? {
        let selector = NSSelectorFromString(selectorName)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    static func callClass(_ className: String, _ selectorName: String) -> AnyObject? {
        guard let cls = objcClass(className) else { return nil }
        return call(cls, selectorName)
    }

    /// Every instance method on a class, for discovering what a moved API became.
    static func instanceMethods(of className: String) -> [String] {
        guard let cls = objcClass(className) else { return [] }
        var count: UInt32 = 0
        guard let list = class_copyMethodList(cls, &count) else { return [] }
        defer { free(list) }
        return (0..<Int(count))
            .map { NSStringFromSelector(method_getName(list[$0])) }
            .sorted()
    }
}

// MARK: - Rung 1: notification discovery

/// Records every notification posted inside Messages.app.
///
/// The point is discovery, not filtering. We do not know which notification carries a typing
/// change — that is the question — so the probe records everything and you correlate against
/// the timestamps of the actions you performed. Filtering to names containing "typing" would
/// answer a question we already know the answer to, since the obvious names do not exist.
final class NotificationRecorder: @unchecked Sendable {

    private var counts: [String: Int] = [:]
    private let lock = NSLock()
    private var observers: [any NSObjectProtocol] = []

    func start() {
        ProbeLog.shared.section("RUNG 1 — notification discovery")
        ProbeLog.shared.write(
            "Recording every notification posted in this process. Perform the actions in "
            + "docs/OBSERVATION_LADDER.md and correlate by timestamp."
        )

        // nil name + nil object: every notification through the default center.
        let local = NotificationCenter.default.addObserver(
            forName: nil, object: nil, queue: nil
        ) { [weak self] notification in
            self?.record(notification, center: "default")
        }
        observers.append(local)

        // Distributed notifications are a separate bus, and some IDS/account state travels
        // over it rather than the in-process one. But a wildcard registration on that bus is
        // a privilege a sandboxed process does not have: the call "succeeds", delivers
        // nothing, and logs a CFGenerateReport backtrace into Messages' stderr that reads
        // exactly like a crash in the probe. Messages.app is sandboxed, so skip it and say so
        // rather than producing an alarming non-event on every run.
        if Sandbox.isSandboxed {
            ProbeLog.shared.write(
                "distributed center: SKIPPED — a sandboxed process cannot observe all "
                + "distributed notifications. Any event found here would need a named "
                + "registration, which requires knowing the name in advance."
            )
        } else {
            let distributed = DistributedNotificationCenter.default().addObserver(
                forName: nil, object: nil, queue: nil
            ) { [weak self] notification in
                self?.record(notification, center: "distributed")
            }
            observers.append(distributed)
        }
    }

    private func record(_ notification: Notification, center: String) {
        let name = notification.name.rawValue

        // Noise floor: AppKit and Foundation post continuously during normal UI activity and
        // would bury the interesting lines. None of these can carry an iMessage event.
        let noisyPrefixes = [
            "NSWindow", "NSView", "NSApplication", "NSMenu", "NSTextView", "NSControl",
            "NSTableView", "NSScrollView", "_NS", "NSUserDefaults", "NSSystemColors",
            "NSViewDidUpdateTrackingAreas", "AppleLanguagePreferences"
        ]
        guard !noisyPrefixes.contains(where: { name.hasPrefix($0) }) else { return }

        lock.lock()
        let seen = counts[name, default: 0]
        counts[name] = seen + 1
        lock.unlock()

        // Full detail on first sight, then a count. A notification that fires 400 times a
        // second is not the one carrying a typing change, but its rate is worth knowing.
        guard seen < 3 else {
            if seen == 3 {
                ProbeLog.shared.write("[\(center)] \(name) — further occurrences suppressed")
            }
            return
        }

        let objectClass = notification.object.map { String(describing: type(of: $0)) } ?? "nil"
        let keys = (notification.userInfo?.keys.map { "\($0)" } ?? []).sorted()
        ProbeLog.shared.write(
            "[\(center)] \(name)  object=\(objectClass)  userInfo=[\(keys.joined(separator: ", "))]"
        )
    }

    /// Call after exercising the actions. The tail of a run is the summary you actually read.
    func summarize() {
        lock.lock()
        let snapshot = counts
        lock.unlock()

        ProbeLog.shared.section("RUNG 1 — summary")
        for (name, count) in snapshot.sorted(by: { $0.value > $1.value }) {
            ProbeLog.shared.write("\(count)\t\(name)")
        }
    }
}

// MARK: - Rung 2: additional listener / delegate

/// Reports whether a SECOND observer can attach to the daemon and FindMy paths.
///
/// This is the rung the whole investigation turns on. Barcelona proves `IMDaemonListener`
/// carries these events — but Barcelona is the ONLY listener in its process. Inside
/// Messages.app there is already one, and whether a second can register alongside it is
/// exactly what has never been tested here.
///
/// The probe does not answer that by reasoning about it. It looks for the registration APIs,
/// reports which exist, and dumps the surrounding method lists so that if the expected
/// selector has moved, the run still tells you what it moved to.
enum ListenerProbe {

    /// Candidate registration points, in the order worth trying.
    ///
    /// `IMDaemonListener.addHandler:` is the most promising: IMCore's own listener is a
    /// fan-out object, and if it accepts additional handlers then rung 2 works with no
    /// swizzling at all. The others are recorded so a run produces evidence either way.
    static let candidates: [(className: String, selector: String, note: String)] = [
        ("IMDaemonController", "sharedInstance", "the controller singleton"),
        ("IMDaemonController", "sharedController", "older name for the same thing"),
        ("IMDaemonListener", "sharedInstance", "the process-wide listener"),
        ("IMChatRegistry", "sharedInstance", "chat-level registry, posts its own notifications"),
        ("IMAccountController", "sharedInstance", "account state, for aliases-removed"),
        ("FMFSessionDataManager", "sharedInstance", "FindMy, currently reached by swizzle"),
        ("IMFMFSession", "sharedInstance", "the IMCore-side FindMy session")
    ]

    static func run() {
        ProbeLog.shared.section("RUNG 2 — listener and delegate registration")

        for candidate in candidates {
            guard Runtime.objcClass(candidate.className) != nil else {
                ProbeLog.shared.write("MISSING  \(candidate.className) — class not present")
                continue
            }
            let instance = Runtime.callClass(candidate.className, candidate.selector)
            ProbeLog.shared.write(
                "\(instance != nil ? "OK      " : "NO SEL  ")"
                + "\(candidate.className).\(candidate.selector) — \(candidate.note)"
            )
        }

        probeDaemonListener()
        probeFindMyDelegate()
    }

    /// The key experiment.
    private static func probeDaemonListener() {
        ProbeLog.shared.section("RUNG 2 — IMDaemonListener handler registration")

        guard let controller = Runtime.callClass("IMDaemonController", "sharedInstance")
                ?? Runtime.callClass("IMDaemonController", "sharedController")
        else {
            ProbeLog.shared.write("No IMDaemonController singleton. Rung 2 is not reachable this way.")
            return
        }

        ProbeLog.shared.write("IMDaemonController is \(type(of: controller))")

        // `listener` is the fan-out object. If it exposes addHandler:, a second observer can
        // attach without disturbing the one Messages.app already has — which is rung 2
        // working, and the outcome that would let us delete the swizzles.
        guard let listener = Runtime.call(controller, "listener") else {
            ProbeLog.shared.write(
                "IMDaemonController has no -listener. Dumping its methods so a renamed "
                + "accessor is still visible:"
            )
            for method in Runtime.instanceMethods(of: "IMDaemonController")
            where method.lowercased().contains("listen") || method.lowercased().contains("handler") {
                ProbeLog.shared.write("  \(method)")
            }
            return
        }

        ProbeLog.shared.write("listener is \(type(of: listener))")

        let registrationSelectors = [
            "addHandler:", "addListenerID:capabilities:", "addListener:",
            "removeHandler:", "handlers"
        ]
        for selector in registrationSelectors {
            let available = Runtime.responds(listener, to: selector)
            ProbeLog.shared.write("\(available ? "AVAILABLE" : "absent   ")  -[listener \(selector)]")
        }

        // The full method list of whatever the listener class turns out to be. This is the
        // most valuable artifact of the whole run: it names every callback rung 2 could
        // deliver, which is what tells you whether typing, aliases, and FindMy are all
        // reachable or only some of them.
        let listenerClassName = String(describing: type(of: listener))
        ProbeLog.shared.write("Methods on \(listenerClassName) mentioning typing/status/account:")
        for method in Runtime.instanceMethods(of: listenerClassName) {
            let lowered = method.lowercased()
            guard lowered.contains("typing") || lowered.contains("status")
                    || lowered.contains("account") || lowered.contains("alias")
                    || lowered.contains("location")
            else { continue }
            ProbeLog.shared.write("  \(method)")
        }
    }

    /// FindMy has a documented delegate protocol, which makes it the most likely rung-2 win.
    ///
    /// `FMFSessionDelegate` declares `didReceiveLocation:` — so the location updates the
    /// helper currently obtains by swizzling `FMFSessionDataManager.setLocations:` are
    /// something the framework already offers to hand you. The open question is only whether
    /// an ADDITIONAL delegate can be attached, since Messages.app is presumably already one.
    private static func probeFindMyDelegate() {
        ProbeLog.shared.section("RUNG 2 — FindMy delegate")

        for className in ["FMFSession", "FMFSessionDataManager", "IMFMFSession"] {
            guard Runtime.objcClass(className) != nil else {
                ProbeLog.shared.write("MISSING  \(className)")
                continue
            }
            let methods = Runtime.instanceMethods(of: className)
                .filter {
                    $0.lowercased().contains("delegate") || $0.lowercased().contains("observer")
                }
            ProbeLog.shared.write("\(className): \(methods.isEmpty ? "no delegate accessors" : methods.joined(separator: ", "))")
        }
    }
}

// MARK: - Rungs 3 and 4: does the current approach still have a surface?

/// Checks that the selectors the shipping helper swizzles still exist.
///
/// Run this on every new macOS BEFORE anything else: if one of these has vanished, the
/// current helper has silently stopped delivering that event, and the symptom users report
/// is "typing indicators stopped working" with nothing in any log.
enum SwizzleTargetProbe {

    static let targets: [(className: String, selector: String, produces: String, rung: Int)] = [
        ("IMChat", "_handleIncomingItem:", "typing indicators (pre-Tahoe)", 3),
        ("IMChat", "_handleIncomingItem:updateReplyCounts:", "typing indicators, newer arity", 3),
        ("IMAccount", "_registrationStatusChanged:", "aliases-removed", 3),
        ("FMFSessionDataManager", "setLocations:", "new-findmy-location", 3),
        ("CKConversationListStandardCell", "setShowTypingIndicator:", "typing indicators (macOS 26+)", 4)
    ]

    static func run() {
        ProbeLog.shared.section("RUNGS 3 and 4 — current swizzle targets")

        for target in targets {
            let present = Runtime.classResponds(target.className, to: target.selector)
            let classPresent = Runtime.objcClass(target.className) != nil
            let status = present ? "PRESENT" : (classPresent ? "SELECTOR GONE" : "CLASS GONE")
            ProbeLog.shared.write(
                "rung \(target.rung)  \(status.padding(toLength: 14, withPad: " ", startingAt: 0))"
                + "\(target.className) \(target.selector) — \(target.produces)"
            )
        }
    }
}

// MARK: - Version

enum EnvironmentProbe {

    /// The slice we were loaded as, which must match the slice Messages is running.
    static var architecture: String {
        #if arch(arm64)
        // Pointer authentication is the observable difference between arm64 and arm64e.
        #if _ptrauth(_arm64e)
        return "arm64e"
        #else
        return "arm64"
        #endif
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    static func run() {
        ProbeLog.shared.section("ENVIRONMENT")
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        ProbeLog.shared.write("macOS: \(version)")
        ProbeLog.shared.write("process: \(ProcessInfo.processInfo.processName)")
        ProbeLog.shared.write("bundle: \(Bundle.main.bundleIdentifier ?? "nil")")
        ProbeLog.shared.write("arch: \(Self.architecture)")
        ProbeLog.shared.write("sandboxed: \(Sandbox.isSandboxed)")
        ProbeLog.shared.write("log: \(ProbeLog.shared.path)")
        ProbeLog.shared.write("IMCore loaded: \(Runtime.objcClass("IMChat") != nil)")
        ProbeLog.shared.write("ChatKit loaded: \(Runtime.objcClass("CKConversationList") != nil)")
    }
}

// MARK: - Entry point

private let recorder = NotificationRecorder()

/// Runs on load, because a dylib injected via DYLD_INSERT_LIBRARIES has no other entry point.
///
/// The delay exists because IMCore classes are not all registered at load time — probing
/// immediately reports classes as missing that appear moments later, which is a false
/// negative that would send the investigation in the wrong direction.
@_cdecl("probe_main")
public func probeMain() {
    ProbeLog.shared.write("")
    ProbeLog.shared.write("################ probe run starting ################")
    EnvironmentProbe.run()

    // Recording starts immediately so nothing during startup is missed.
    recorder.start()

    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
        SwizzleTargetProbe.run()
        ListenerProbe.run()
        ProbeLog.shared.section("READY")
        ProbeLog.shared.write(
            "Now perform the actions in docs/OBSERVATION_LADDER.md. A summary is written "
            + "after 5 minutes, or immediately on SIGUSR1."
        )
    }

    // Summarize on demand, so you do not have to wait out the timer once you are done.
    let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    source.setEventHandler { recorder.summarize() }
    source.resume()
    signalSource = source

    DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
        recorder.summarize()
    }
}

private nonisolated(unsafe) var signalSource: (any DispatchSourceSignal)?

/// The dylib constructor. `DYLD_INSERT_LIBRARIES` calls this without any cooperation from
/// Messages.app.
@_cdecl("probe_initializer")
public func probeInitializer() {
    probeMain()
}
