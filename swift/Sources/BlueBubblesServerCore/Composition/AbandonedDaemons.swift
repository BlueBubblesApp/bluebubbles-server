//  AbandonedDaemons
//  The one thing a process on its way out can still do for the daemons it could not stop.

import BBProxy
import Logging

extension RunningServer {

  /// Sends SIGTERM to every daemon this server spawned that is still running.
  ///
  /// For the exits that could not wait for `stop()` (the app's shutdown deadline, the
  /// CLI after its orderly stop) so a daemon abandoned mid-restart does not go on holding
  /// its tunnel parented to launchd. One syscall per daemon and no waiting, which is all a
  /// deadline-bound exit has room for. The next start finishes the job if a signal was
  /// ignored: see `DaemonLedger.reapOrphans`.
  public func terminateAbandonedDaemons() {
    DaemonLedger.shared.terminateAll(logger: Logger(label: "bluebubbles.proxy.daemon"))
  }
}
