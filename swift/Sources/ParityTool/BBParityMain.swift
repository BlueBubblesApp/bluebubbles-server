//  bb-parity
//  Runs the side-by-side comparison.
//
//  Both servers, same Mac, same messages, same questions. This is the last check before
//  cutover — recorded fixtures prove the Swift server matches what the Node server said when
//  they were recorded; this proves it matches what the Node server says now.
//
//  Usage:
//    swift run bb-parity \
//      --reference http://localhost:1234 --reference-password "$NODE_PW" \
//      --candidate http://localhost:1235 --candidate-password "$SWIFT_PW"
//
//  Add `--chat-guid` to include the per-chat reads. Nothing in the corpus writes.

import ArgumentParser
import BBParity
import Foundation

@main
struct BBParity: AsyncParsableCommand {

  static let configuration = CommandConfiguration(
    commandName: "bb-parity",
    abstract: "Diff a Node server and a Swift server answering identical requests."
  )

  @Option(help: "Base URL of the reference (Node) server.")
  var reference: String = "http://localhost:1234"

  @Option(help: "Base URL of the candidate (Swift) server.")
  var candidate: String = "http://localhost:1235"

  @Option(help: "Password for the reference server. Also read from BB_REFERENCE_PASSWORD.")
  var referencePassword: String?

  @Option(help: "Password for the candidate server. Also read from BB_CANDIDATE_PASSWORD.")
  var candidatePassword: String?

  @Option(help: "A chat GUID to exercise the per-chat reads against.")
  var chatGuid: String?

  @Flag(help: "Print every request, including the ones that match.")
  var verbose = false

  func run() async throws {
    // Environment first for the passwords, so a real one need not appear in shell
    // history or the process table.
    let environment = ProcessInfo.processInfo.environment
    guard let referenceSecret = referencePassword ?? environment["BB_REFERENCE_PASSWORD"] else {
      throw ValidationError(
        "No reference password. Pass --reference-password or set BB_REFERENCE_PASSWORD."
      )
    }
    guard let candidateSecret = candidatePassword ?? environment["BB_CANDIDATE_PASSWORD"] else {
      throw ValidationError(
        "No candidate password. Pass --candidate-password or set BB_CANDIDATE_PASSWORD."
      )
    }

    let requests = Corpus.resolved(chatGUID: chatGuid)
    if chatGuid == nil {
      FileHandle.standardError.write(
        Data(
          "note: no --chat-guid, so the per-chat reads are skipped.\n".utf8
        ))
    }

    let runner = SideBySideRunner(
      reference: ServerEndpoint(
        name: "node", baseURL: reference, password: referenceSecret
      ),
      candidate: ServerEndpoint(
        name: "swift", baseURL: candidate, password: candidateSecret
      )
    )

    let results = await runner.run(requests)

    // The full set is always what is summarised; `--verbose` only decides whether the
    // matching lines are listed too.
    if results.allMatch, !verbose {
      print("All \(results.count) endpoints match.")
    } else {
      print(results.report(showingMatches: verbose))
    }

    // A non-zero exit so this can gate a cutover script rather than being read by eye.
    if !results.allMatch {
      throw ExitCode(1)
    }
  }
}
