//  TerminationSignals
//  SIGINT and SIGTERM, delivered to a handler instead of ending the process.
//
//  Both binaries need the same three steps, and each step has a failure that makes no
//  noise. SIG_IGN first: a `DispatchSourceSignal` only sees a signal whose default action
//  has been suppressed, and without it the default disposition kills the process before
//  the handler runs, so tunnels are never told to close. Then the sources must outlive the
//  wait: a released source stops delivering, SIG_IGN stays behind, and the process ignores
//  every later `kill` with nothing listening. And two signals in a row are normal (a
//  terminal sends SIGINT and a supervisor follows with SIGTERM), so a one-shot wait must
//  survive the second.
//
//  The app quits through `NSApplication.terminate` on every signal; the CLI waits for the
//  first and then shuts down. Those are the two shapes below. What each does with the signal
//  is its own business, including whether to log it: BBCore has no logging stack.

import Dispatch
import Foundation

public final class TerminationSignals: @unchecked Sendable {

  /// The signals handled. SIGHUP is deliberately absent: a headless server started from a
  /// terminal that is then closed should keep running.
  public static let handled: [Int32] = [SIGINT, SIGTERM]

  // Immutable after init; held only so the sources live as long as this object does.
  private let sources: [any DispatchSourceSignal]

  /// Starts delivering every handled signal to `handler`, on `queue`, for the life of the
  /// returned object. Keep it: releasing it stops delivery while the signals stay ignored.
  public init(queue: DispatchQueue = .main, handler: @escaping @Sendable (Int32) -> Void) {
    sources = Self.handled.map { value in
      signal(value, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: value, queue: queue)
      source.setEventHandler { handler(value) }
      source.resume()
      return source
    }
  }

  deinit {
    for source in sources { source.cancel() }
  }

  /// Suspends until the first handled signal arrives, and returns it.
  ///
  /// A later signal is ignored rather than resuming anything twice, and it stays ignored
  /// after this returns: a second Ctrl-C during the shutdown that follows must not kill the
  /// process half way through closing its tunnels.
  public static func first(queue: DispatchQueue = .main) async -> Int32 {
    let (stream, continuation) = AsyncStream<Int32>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    let signals = TerminationSignals(queue: queue) { continuation.yield($0) }
    var iterator = stream.makeAsyncIterator()
    let received = await iterator.next()
    withExtendedLifetime(signals) {}
    // `next` only answers nil if the waiting task is cancelled, and a cancelled wait for
    // a stop signal is a request to stop too.
    return received ?? SIGTERM
  }
}
