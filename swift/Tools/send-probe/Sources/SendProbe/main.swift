//  send-probe
//  Sends a real message through the AppleScript path, and reports which chat-GUID spelling
//  actually resolved.
//
//  That last part is the interesting output on macOS 26: the service prefix was migrated to
//  `any`, and `chat id "iMessage;-;X"` now fails with -1728 while `any;-;X` succeeds. The
//  sender tries every spelling, so this prints the one that worked.

import BBAppleScript
import BBCore
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard let guid = arguments.first else {
    let name = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "send-probe"
    print("""
        usage: \(name) '<chat-guid>' [message]

          \(name) 'iMessage;-;someone@example.com'
          \(name) 'any;+;chat000000000000000001' 'hello from the Swift port'

        Requires Automation permission for Messages. Sends a REAL message.
        """)
    exit(2)
}

let text = arguments.count > 1
    ? arguments[1]
    : "BlueBubbles Swift port — AppleScript send path probe \(ISO8601DateFormatter().string(from: Date()))"

let sender = AppleScriptMessageSender()
nonisolated(unsafe) var exitCode: Int32 = 0

// Reported up front so a failure is diagnosable without reading the source.
if let parsed = ChatGUID(guid) {
    print("requested : \(parsed)")
    print("candidates: \(parsed.lookupCandidates().joined(separator: ", "))")
}
print("services  : \(MessagesScripts.supportedServices().map(\.rawValue).joined(separator: ", "))")

// The send is kicked off as a task and the MAIN RUN LOOP is pumped until it finishes.
// AppleScript's remote send waits on the Carbon event loop, which is driven from here; a
// plain top-level `await` parks the main thread in the concurrency executor instead, and the
// reply never arrives.
nonisolated(unsafe) var finished = false

Task {
    defer { finished = true }
    do {
        let resolved = try await sender.send(chatGUID: guid, text: text)
        print("resolved  : \(resolved)")
        print("result    : sent")
    } catch let error as MessageSendError {
        print("result    : FAILED — \(error)")
        switch error {
        case .automationNotPermitted:
            print("""

                Automation permission is missing. Grant it in
                System Settings -> Privacy & Security -> Automation, for whichever process
                ran this, with Messages enabled underneath it.
                """)
        case .messagesNotRunning:
            print("\nMessages is not running. Open it and retry.")
        default:
            break
        }
        exitCode = 1
    } catch {
        print("result    : FAILED — \(error)")
        exitCode = 1
    }
}

while !finished, RunLoop.main.run(mode: .default, before: .distantFuture.addingTimeInterval(0)) {
    if finished { break }
}
exit(exitCode)
