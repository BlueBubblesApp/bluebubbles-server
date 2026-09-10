//  PrivateAPIStateStreamTests
//  The runtime's state stream, which the settings page follows instead of polling.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBPrivateAPI
import Foundation
import Testing

private func firstState(
  in stream: AsyncStream<PrivateAPIRuntime.State>,
  timeout: Duration = .seconds(5)
) async -> PrivateAPIRuntime.State? {
  await withTaskGroup(of: PrivateAPIRuntime.State?.self) { group in
    group.addTask {
      for await state in stream { return state }
      return nil
    }
    group.addTask {
      try? await Task.sleep(for: timeout)
      return nil
    }
    let first = await group.next() ?? nil
    group.cancelAll()
    return first
  }
}

@Suite("Private API state stream")
struct PrivateAPIStateStreamTests {

  /// A runtime that is switched off never opens a socket, so this is the one outcome a test
  /// can drive end to end without Messages.
  @Test("A start that declines publishes its outcome")
  func disabledStartPublishes() async throws {
    let runtime = PrivateAPIRuntime(
      configuration: PrivateAPIConfiguration(
        isEnabled: false,
        socketPath: NSTemporaryDirectory() + "bb-state-\(UUID().uuidString.prefix(8)).sock"
      )
    )
    let changes = await runtime.states()
    #expect(await runtime.state == .init(outcome: .notStarted, isConnected: false))

    try await runtime.start()

    let published = await firstState(in: changes)
    #expect(published == .init(outcome: .disabled, isConnected: false))
    #expect(await runtime.state.outcome == .disabled)
  }
}
