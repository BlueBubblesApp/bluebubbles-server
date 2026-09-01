//  MessagesScripts
//  The AppleScript that survives the port: send to a chat, and send to a participant.
//
//  THERE IS NO START-CHAT HANDLER, AND ON EVERY SUPPORTED macOS THERE CANNOT BE ONE.
//  ---------------------------------------------------------------------------------
//  `make new chat` has been broken since **Big Sur (macOS 11)** — three releases below this
//  package's macOS 14 floor, so it is dead on Sonoma, Sequoia and Tahoe alike. This is not
//  an extrapolation from the newest system: the Node server this port replaces states it
//  outright and refuses the call before making it.
//
//      // packages/server/src/server/api/interfaces/chatInterface.ts
//      if (method == 'apple-script' && isMinBigSur && addresses.length > 1) {
//          throw new Error("Cannot create group chats on macOS Big Sur or newer!");
//      }
//
//  Independently measured on macOS 26.5.2, where it fails with -10000 (AppleEvent handler
//  failed) **even with no properties at all**, so it never reaches participant handling.
//  Nine spellings were tried, including `at end of chats`, `with data`, the pre-Big-Sur
//  `make new text chat` (-1728, the class is gone) and the JXA `chats.push()` form. The
//  `sdef` agrees: every `chat` element is `access="r"` and the class declares no
//  `responds-to` for `make`. The participant element's "may be specified at time of
//  creation" is leftover iChat-era text.
//
//  A `bbStartChat` handler used to live here. It compiled, so it looked fine, and it failed
//  at runtime — nothing called it, and `send-probe` only exercises `bbSendToChat`, which is
//  why that went unnoticed. **Do not add it back, and do not add a version gate for it:**
//  there is no supported macOS on which it would run.
//
//  What still works without the helper is the ONE-TO-ONE case, and only because it does not
//  create anything explicitly: sending to a participant that has no conversation yet makes
//  Messages open one. That is `bbSendToParticipant`. Group creation has no AppleScript route
//  at all and goes through `BBShortcuts`.
//
//  Everything else in the current server's 31 inline scripts is dropped — the accessibility
//  GUI-puppetry ones have Private API equivalents, and the rest were already dead. See
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
//     does not define is a COMPILE failure, not a runtime one — it would take out sending
//     entirely rather than just the unsupported case. `RCS` is exactly that: present in the
//     macOS 26 dictionary, absent earlier. Composing structure from constants is safe;
//     composing it from user input is what we are avoiding.
//
//  What the macOS 14 floor already bought us
//  -----------------------------------------
//  The Node implementation branches three ways on OS version. Verified against the Messages
//  `sdef` on macOS 26, whose only classes are `participant`, `account`, `chat` and
//  `file transfer`, every one of those branches collapses:
//
//      `service`   -> `account`      (Ventura+)
//      `buddy`     -> `participant`  (Big Sur+)
//
//  (The Node server's third branch, `make new text chat` -> `make new chat`, is gone for a
//  different reason: on Big Sur+ neither spelling works. See above.)
//
//  None of the pre-Sonoma spellings are carried over. This is the Mojave-era compatibility
//  the Swift helper gets to delete.

import BBCore
import Foundation

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
    applicationPath: String = "/System/Applications/Messages.app"
  ) -> [MessagingService] {
    var available: [MessagingService] = [.iMessage, .sms]
    guard let definition = scriptingDefinition(at: applicationPath) else { return available }
    if definition.contains("\"RCS\"") || definition.contains("name=\"RCS\"") {
      available.append(.rcs)
    }
    return available
  }

  /// Synchronous, and this is the one place that has to be.
  ///
  /// It feeds a DEFAULT ARGUMENT — `source(services:)` defaults to `supportedServices()`,
  /// which calls this — and a default argument cannot be `async`. See
  /// `Subprocess.runSynchronously`, which exists for exactly this shape.
  static func scriptingDefinition(at path: String) -> String? {
    guard
      let result = try? Subprocess.runSynchronously(
        "/usr/bin/sdef", [path], output: .standardOutputOnly, timeout: .seconds(15)
      ),
      result.succeeded
    else { return nil }
    return result.text
  }
}
