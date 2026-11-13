//  MessagesScripts
//  The AppleScript that survives the port: send to a chat, and send to a participant.
//
//  THERE IS NO START-CHAT HANDLER, AND ON EVERY SUPPORTED macOS THERE CANNOT BE ONE.
//  ---------------------------------------------------------------------------------
//  `make new chat` has been broken since **Big Sur (macOS 11)**: three releases below this
//  package's macOS 14 floor, so it is dead on Sonoma, Sequoia and Tahoe alike. This is not
//  an extrapolation from the newest system: the reference states it outright and refuses an
//  AppleScript create with more than one address on Big Sur or later, with "Cannot create
//  group chats on macOS Big Sur or newer!", before making the call.
//
//  Independently measured on macOS 26.5.2, where it fails with -10000 (AppleEvent handler
//  failed) **even with no properties at all**, so it never reaches participant handling.
//  Nine spellings were tried, including `at end of chats`, `with data`, the pre-Big-Sur
//  `make new text chat` (-1728, the class is gone) and the JXA `chats.push()` form. The
//  `sdef` agrees: every `chat` element is `access="r"` and the class declares no
//  `responds-to` for `make`. The participant element's "may be specified at time of
//  creation" is leftover iChat-era text.
//
//  **Do not add a `bbStartChat` handler, and do not add a version gate for one:** there is
//  no supported macOS on which it would run. One compiles, so it looks fine, and fails at
//  runtime, and `send-probe` exercises only `bbSendToChat`, so nothing would catch it.
//
//  What still works without the helper is the ONE-TO-ONE case, and only because it does not
//  create anything explicitly: sending to a participant that has no conversation yet makes
//  Messages open one. That is `bbSendToParticipant`. Group creation has no AppleScript route
//  at all and goes through `BBShortcuts`.
//
//  Nothing else is scripted: GUI puppetry has Private API equivalents. See
//  `.claude/docs/imessage.md` for the capability table and the accepted regression.
//
//  Two rules hold throughout this file:
//
//  1. **User values are never interpolated.** They arrive as Apple Event parameters. That is
//     what removes `escapeOsaExp` and, with it, the class of bug where a quote or backslash
//     in a message breaks the send.
//
//  2. **Script STRUCTURE may be version-gated, and sometimes must be.** AppleScript compiles
//     against the running system's scripting dictionary, so naming a term the local Messages
//     does not define is a COMPILE failure, not a runtime one; it would take out sending
//     entirely rather than just the unsupported case. `RCS` is exactly that: present in the
//     macOS 26 dictionary, absent earlier. Composing structure from constants is safe;
//     composing it from user input is what we are avoiding.
//
//  Terms, on the macOS 14 floor
//  ----------------------------
//  Verified against the Messages `sdef` on macOS 26, whose only classes are `participant`,
//  `account`, `chat` and `file transfer`:
//
//      `service`   -> `account`      (Ventura+)
//      `buddy`     -> `participant`  (Big Sur+)
//
//  No pre-Sonoma spelling is needed, and `make new text chat` -> `make new chat` is moot: on
//  Big Sur+ neither works. See above.

import BBCore
import Foundation
import Logging

public enum MessagesScripts {

  /// Cache key. Bumped when the source changes so a long-lived process does not keep
  /// running a stale compilation.
  public static let cacheKey = "messages.send.v1"

  public static let sendToChat = "bbSendToChat"
  public static let sendToParticipant = "bbSendToParticipant"

  /// The compiled script's source.
  ///
  /// - Parameter services: Which `service type` enumerators the local Messages dictionary
  ///   defines. Naming one it does not know fails compilation, taking every handler in this
  ///   script with it.
  public static func source(services: [MessagingService] = supportedServices()) -> String {
    """
    -- Resolves a service name to an account.
    --
    -- Branching here rather than interpolating the service into the source keeps the
    -- script constant, so it compiles once and every value stays a parameter.
    on bbAccountForService(serviceName)
        tell application "Messages"
    \(accountBranches(for: services))
        end tell
    end bbAccountForService

    -- Sends to an existing chat, addressed by GUID. The primary path.
    on \(sendToChat)(chatGuid, messageText, attachmentPath)
        tell application "Messages"
            set targetChat to a reference to chat id chatGuid
            \(sendBody(target: "targetChat"))
        end tell
        return "sent"
    end \(sendToChat)

    -- Sends to an address directly, for a one-to-one chat that has no GUID yet.
    on \(sendToParticipant)(address, serviceName, messageText, attachmentPath)
        set targetAccount to my bbAccountForService(serviceName)
        tell application "Messages"
            set targetParticipant to participant address of targetAccount
            \(sendBody(target: "targetParticipant"))
        end tell
        return "sent"
    end \(sendToParticipant)

    """
  }

  /// Attachment first, then text, with the delay between them.
  ///
  /// The delay is not superstition: Messages processes a file transfer asynchronously, and
  /// sending the caption immediately after can deliver the two out of order. The current
  /// server has the same `delay 1` for the same reason.
  private static func sendBody(target: String) -> String {
    """
    if attachmentPath is not "" then
                    set theAttachment to attachmentPath as POSIX file
                    send theAttachment to \(target)
                    delay 1
                end if
                if messageText is not "" then
                    send messageText to \(target)
                end if
    """
  }

  private static func accountBranches(for services: [MessagingService]) -> String {
    // iMessage is the fallback branch, so it is never part of the if-chain.
    let alternatives = services.filter { $0 != .iMessage }
    var lines: [String] = []
    for service in alternatives {
      let keyword = lines.isEmpty ? "if" : "else if"
      lines.append("        \(keyword) serviceName is \"\(service.rawValue)\" then")
      lines.append(
        "            return 1st account whose service type = \(service.appleScriptEnumerator)")
    }
    if lines.isEmpty {
      return "        return 1st account whose service type = iMessage"
    }
    lines.append("        else")
    lines.append("            return 1st account whose service type = iMessage")
    lines.append("        end if")
    return lines.joined(separator: "\n")
  }

  /// Which service enumerators the local Messages dictionary defines.
  ///
  /// Read from the dictionary rather than from the OS version, for the same reason
  /// `SchemaProfile` introspects chat.db instead of trusting `sw_vers`: the artifact is the
  /// authority on itself, and this one decides whether the script compiles at all.
  public static func supportedServices(
    applicationPath: String = "/System/Applications/Messages.app",
    logger: Logger = Logger(label: "bluebubbles.applescript")
  ) -> [MessagingService] {
    // MEMOISED. Every `AppleScriptMessageSender` asks when it is built, and the answer cannot
    // change while Messages.app is the one on disk, so only the first one reads this file.
    //
    // Keyed by path because the argument exists and tests pass a fixture. A cache rather
    // than a `static let` for the same reason: a `static let` cannot take a parameter.
    if let cached = serviceCache.withLock({ $0[applicationPath] }) {
      return cached
    }

    let definition = scriptingDefinition(at: applicationPath)
    var available: [MessagingService] = [.iMessage, .sms]
    if let definition, definition.contains("\"RCS\"") || definition.contains("name=\"RCS\"") {
      available.append(.rcs)
    }

    // Two callers racing here both read and both store the same answer, which costs one
    // extra read on a cold start and avoids holding a lock across file I/O. Only the caller
    // that stored it may warn, so a process says this once however many senders it builds.
    let isFirstAnswer = serviceCache.withLock { cache in
      guard cache[applicationPath] == nil else { return false }
      cache[applicationPath] = available
      return true
    }
    if definition == nil, isFirstAnswer {
      logger.warning(
        "Could not read the Messages scripting dictionary, so RCS is not available to AppleScript. A new chat asking for RCS goes over iMessage instead."
      )
    }
    return available
  }

  private static let serviceCache = Locked<[String: [MessagingService]]>([:])

  /// The dictionary file inside the application, never `/usr/bin/sdef`.
  ///
  /// `/usr/bin/sdef` is an `xcode-select` stub that needs a full Xcode: Command Line Tools do
  /// not include it (measured on macOS 14.6.1 and 27.0.1), and with no developer tools at all
  /// the system offers to install them. So asking it fails on almost every Mac this server
  /// runs on, and loses `RCS` with nothing to say why. The file answers the same question on
  /// every Mac, and `Info.plist` names it.
  ///
  /// Synchronous because it feeds a DEFAULT ARGUMENT (`source(services:)` defaults to
  /// `supportedServices()`, which calls this), and a default argument cannot be `async`.
  static func scriptingDefinition(at path: String) -> String? {
    guard
      let bundle = Bundle(path: path),
      let declared = bundle.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String,
      let url = bundle.url(
        forResource: (declared as NSString).deletingPathExtension, withExtension: "sdef")
    else { return nil }
    // `try?`: `supportedServices` reports nil in a warning, then leaves out `RCS`, the choice
    // that still compiles.
    return try? String(contentsOf: url, encoding: .utf8)
  }
}
