//  StartWindow
//  Whether a daemon start is in flight, and whether the daemon exited during it.
//
//  An exit inside the window is RECORDED, not acted on. Whoever is starting owns the daemon
//  until the start returns, and `DaemonProcess.start` owns a single readiness continuation: a
//  restart begun from the exit handler would race it, leaving one of the two waiters with
//  nothing to resume it, or start a loop behind a start that then stops the daemon the loop
//  just brought back. The starter reads the record once its own work is settled and acts on
//  it then. Both supervised tunnels keep this; one type, so the rule cannot drift between them.

struct StartWindow {

  private(set) var isOpen = false
  private var exitedInside = false

  /// A start is beginning. Clears any exit recorded for an earlier one.
  mutating func open() {
    isOpen = true
    exitedInside = false
  }

  mutating func close() { isOpen = false }

  /// Notes that the daemon exited. True when no start is in flight and the caller should act
  /// on the exit now; false when it was recorded for the starter.
  mutating func noteExit() -> Bool {
    guard isOpen else { return true }
    exitedInside = true
    return false
  }

  /// Reads and clears whether the daemon exited while a start was in flight.
  mutating func consumeExit() -> Bool {
    defer { exitedInside = false }
    return exitedInside
  }
}
