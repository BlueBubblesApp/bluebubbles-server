//  DaemonOutputRaceTests
//  The one thing a daemon that dies immediately must still do: say why.
//
//  `DaemonTests` covers this once, and once is not enough — the failure is a race between the
//  pipe's readability handler and the termination path, so a single attempt passes almost
//  always and fails at whatever rate the machine's scheduler happens to produce. It was found
//  as an intermittent red in CI-shaped runs, which is the worst way to find anything.
//
//  Repeating it turns a scheduling coin-flip into something a test can assert. The daemons here
//  print one line and exit immediately, which is exactly the shape that loses the race: the
//  handler empties the pipe, and without somewhere durable to put those bytes the termination
//  path finds nothing and reports an empty explanation.
//
//  If this ever goes red again, the symptom in production is a user being told their tunnel
//  "exited with code 1" while the line naming their expired authtoken is dropped on the floor.

import BBCore
import Foundation
import Testing

@testable import BBProxy

@Suite("Daemon output is never lost", .serialized)
struct DaemonOutputRaceTests {

  /// Enough attempts to catch a race that shows up in a few percent of runs.
  private static let attempts = 60
  /// How many run at once.
  ///
  /// Concurrency is what makes the race appear at all — the losing interleaving needs the
  /// scheduler to have something better to do — but it is also what makes this test a bad
  /// neighbour. Sixty simultaneous shells took the test host from 120 MB to 1.1 GB and
  /// pushed `MemoryBudgetTests` and `DylibInjectorTests`, which run in parallel and measure
  /// footprint and timing, into failing on work that was not theirs. Batching keeps the
  /// pressure that finds the bug and drops the peak that breaks everyone else.
  private static let batchSize = 20

  @Test("A daemon that prints and exits always carries its output")
  func earlyExitAlwaysCarriesOutput() async throws {
    // Run CONCURRENTLY, which is the condition that makes this fail. The race is between a
    // `Task` carrying bytes to the actor and the termination path reading the pipe, so it
    // is lost only when the scheduler has something better to do — which is why a serial
    // loop of the same daemons passes every time and the bug was first seen in a full test
    // run, under load, at a few percent.
    var lostOutput = 0
    var timedOut = 0
    for batch in stride(from: 0, to: Self.attempts, by: Self.batchSize) {
      let result = await runBatch(startingAt: batch)
      lostOutput += result.lostOutput
      timedOut += result.timedOut
    }

    // Counted rather than asserted per attempt, so a regression reports HOW often it
    // happens — the difference between "the race is back" and "something else broke".
    #expect(lostOutput == 0, "\(lostOutput) of \(Self.attempts) failures carried no output")
    let timeoutMessage =
      "\(timedOut) of \(Self.attempts) waited out the readiness "
      + "timeout for a process that had already exited"
    #expect(timedOut == 0, Comment(rawValue: timeoutMessage))
  }

  /// One batch of concurrent early-exit daemons; returns how many lost their output.
  private func runBatch(startingAt offset: Int) async -> (lostOutput: Int, timedOut: Int) {
    await withTaskGroup(of: Outcome.self) { group in
      for attempt in (offset + 1)...(offset + Self.batchSize) {
        group.addTask {
          let daemon = DaemonProcess(
            configuration: DaemonConfiguration(
              name: "race-\(attempt)",
              executablePath: "/bin/sh",
              arguments: [
                "-c", "echo 'ERR_NGROK_108: your authtoken is invalid' >&2; exit 1",
              ],
              restartDelay: .milliseconds(1)
            )
          )
          let signal = ReadinessSignal(timeout: .seconds(10)) { line in
            line.contains("url=") ? line : nil
          }
          do {
            _ = try await daemon.start(waitingFor: signal)
            return .unexpectedSuccess
          } catch let error as DaemonError {
            switch error {
            case .exitedBeforeReady(_, let output):
              // The pipe race: the exit was reported, its explanation was not.
              return output.contains("ERR_NGROK_108") ? .reported : .lostOutput
            case .readyTimeout:
              // The registration race: the daemon was dead within milliseconds
              // and the caller waited out the entire timeout to be told the
              // wrong thing.
              return .timedOut
            default:
              return .lostOutput
            }
          } catch {
            return .lostOutput
          }
        }
      }
      var lost = 0
      var timedOut = 0
      for await outcome in group {
        switch outcome {
        case .reported: break
        case .lostOutput, .unexpectedSuccess: lost += 1
        case .timedOut: timedOut += 1
        }
      }
      return (lost, timedOut)
    }
  }

  /// What one attempt did. Separated because the two failures have different causes and
  /// different fixes, and a single "it went wrong" count hid the second one entirely.
  private enum Outcome {
    /// Failed, and said why. The only acceptable outcome.
    case reported
    /// Failed without its output, or in some way not expected at all.
    case lostOutput
    /// Waited out the readiness timeout for a process that was already dead.
    case timedOut
    case unexpectedSuccess
  }

  /// The same race seen from the other side: output that arrives while the process is still
  /// alive must survive too, so a diagnostic report is not empty for a healthy daemon.
  @Test("Output printed before a clean stop is retained")
  func outputSurvivesUntilStopped() async throws {
    for attempt in 1...10 {
      let daemon = DaemonProcess(
        configuration: DaemonConfiguration(
          name: "retain-\(attempt)",
          executablePath: "/bin/sh",
          // `exec`, and it is load-bearing. Without it `sh` forks a `sleep` that
          // INHERITS the pipe's write end, so terminating `sh` leaves an orphan
          // holding it open — and the drain at termination then blocks on a read
          // that cannot return until the orphan exits. That is thirty seconds per
          // iteration, and it is a property of the fixture rather than of the code
          // under test.
          arguments: ["-c", "echo 'url=https://example.ngrok-free.app'; exec sleep 30"]
        )
      )
      let url = try await daemon.start(
        waitingFor: ReadinessSignal(timeout: .seconds(5)) { line in
          line.contains("url=") ? String(line.dropFirst("url=".count)) : nil
        }
      )
      #expect(url == "https://example.ngrok-free.app")
      let retained = await daemon.recentOutput
      #expect(retained.contains { $0.contains("ngrok-free.app") })
      await daemon.stop()
    }
  }
}
