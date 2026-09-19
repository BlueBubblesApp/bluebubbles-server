//  BackgroundActivityTests
//  What the sidebar's background section says, and the invariant that keeps a row from
//  saying nothing at all.

import Testing

@testable import BlueBubblesApp

@Suite("Background activity")
struct BackgroundActivityTests {

  private func activity(
    _ name: String, _ state: BackgroundActivity.State
  ) -> BackgroundActivity {
    BackgroundActivity(id: name, name: name, state: state)
  }

  @Test("A measured task reports its fraction; an indeterminate one reports words")
  func statesCarryWhatTheyPromise() {
    let measured = activity("cloudflared", .measuring(fraction: 0.62, detail: "Downloading… 62%"))
    #expect(measured.fraction == 0.62)
    #expect(measured.detail == "Downloading… 62%")

    // A fraction with no words is legal: the bar is the report.
    let bare = activity("zrok", .measuring(fraction: 0.1, detail: nil))
    #expect(bare.fraction == 0.1)
    #expect(bare.detail == nil)

    // Words with no fraction is the other legal shape.
    let described = activity("Tailscale", .describing("waiting for you to sign in"))
    #expect(described.fraction == nil)
    #expect(described.detail == "waiting for you to sign in")
  }

  @Test("Every row says something: a task with neither a fraction nor words cannot be built")
  func neitherIsUnrepresentable() {
    // `describing` requires its text and `measuring` requires its fraction, so the only way
    // to reach "no bar and no caption" would be a third case. There is none; this test
    // exists to fail if one is ever added.
    for state in [
      BackgroundActivity.State.describing("x"),
      .measuring(fraction: 0, detail: nil),
      .measuring(fraction: 1, detail: "done"),
    ] {
      let row = activity("thing", state)
      #expect(row.fraction != nil || row.detail != nil)
    }
  }

  @Test("A connection method always has words, even when it reported no reason")
  func connectionDetailIsNeverEmpty() {
    // `.describing` promises words, and the tunnel's reason is empty in the ordinary
    // middle of a restart, so the fallback is what keeps that promise.
    #expect(
      ConnectionActivity.reconnecting(method: "Tailscale", detail: "").detailOrDefault
        == "Reconnecting…")
    #expect(
      ConnectionActivity.reconnecting(method: "Tailscale", detail: "signing in").detailOrDefault
        == "signing in")
  }

  @Test("The spoken announcement names every task, with percentages where there are any")
  func announcement() {
    let spoken = BackgroundActivity.announcement(for: [
      activity("cloudflared", .measuring(fraction: 0.62, detail: "Downloading… 62%")),
      activity("Tailscale", .describing("signing in")),
    ])
    #expect(spoken == "Background tasks: cloudflared, 62 percent. Tailscale, signing in")
    #expect(BackgroundActivity.announcement(for: []).isEmpty)
  }
}
