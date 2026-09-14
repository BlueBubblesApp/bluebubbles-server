//  APIReachabilityTests
//
//  `server_address` holds whatever the connection method last published, and nothing clears
//  it when the listener stops. Home and Guides read it to answer "what do I type into the
//  phone", so without this policy both pages went on handing out a URL for a server that
//  refuses every connection.

import BBServiceKit
import Testing

@testable import BlueBubblesApp

@Suite("API reachability")
struct APIReachabilityTests {

  @Test("An address is only shown when something is listening")
  func onlyServingShowsTheAddress() {
    #expect(
      APIReachability.of(isServerRunning: true, isListenerEnabled: true, listenerHealth: .running)
        == .reachable)
    #expect(APIReachability.reachable.showsAddress)

    let listenerOff = APIReachability.of(
      isServerRunning: true, isListenerEnabled: false, listenerHealth: .running)
    #expect(listenerOff == .listenerSwitchedOff)
    #expect(!listenerOff.showsAddress)
  }

  /// A stopped server outranks the listener's own switch. Both are true, and "start the
  /// server" is the step that has to happen first, so it is the one worth saying.
  @Test("A stopped server is reported as stopped, whatever the listener's switch says")
  func stoppedOutranksSwitchedOff() {
    #expect(
      APIReachability.of(isServerRunning: false, isListenerEnabled: true, listenerHealth: .running)
        == .serverStopped)
    #expect(
      APIReachability.of(isServerRunning: false, isListenerEnabled: false, listenerHealth: .running)
        == .serverStopped)
    #expect(!APIReachability.serverStopped.showsAddress)
  }

  /// Every stand-in names the next step. "Not set" would be wrong in all three: nobody sets
  /// this value, the connection method publishes it.
  @Test("Each reason has its own words, and only the surprising one adds a note")
  func wording() {
    #expect(
      APIReachability.serverStopped.addressPlaceholder
        == "start the server to publish an address")
    #expect(
      APIReachability.listenerSwitchedOff.addressPlaceholder
        == "the HTTP API is switched off")
    #expect(APIReachability.reachable.addressPlaceholder == "not published yet")

    // A running server with the listener off is the state nothing else on the page
    // explains, so it is the only one that earns a sentence.
    #expect(APIReachability.reachable.note == nil)
    #expect(APIReachability.serverStopped.note == nil)
    #expect(APIReachability.listenerSwitchedOff.note != nil)
  }

  /// The case the wiring could not see. A service whose `start()` throws leaves the switch
  /// on and the phase running, so only its own health distinguishes it.
  @Test("A listener that failed to start is not reachable, and says why")
  func failedListenerIsNotReachable() {
    let failed = APIReachability.of(
      isServerRunning: true, isListenerEnabled: true,
      listenerHealth: .failed(reason: "port 1234 is already in use"))
    #expect(failed == .listenerFailed(reason: "port 1234 is already in use"))
    #expect(!failed.showsAddress)
    #expect(failed.addressPlaceholder == "the HTTP API did not start")
    #expect(failed.note?.contains("port 1234 is already in use") == true)

    let inactive = APIReachability.of(
      isServerRunning: true, isListenerEnabled: true,
      listenerHealth: .inactive(reason: "no certificate"))
    #expect(inactive == .listenerFailed(reason: "no certificate"))
  }

  /// Transient states must NOT read as a failure, or every start flickers a warning.
  @Test("Starting, stopped, degraded and unknown all still show the address")
  func transientStatesAreNotFailures() {
    for health: ServiceHealth? in [
      nil, .starting, .stopped, .running, .degraded(reason: "rate limited"),
    ] {
      #expect(
        APIReachability.of(
          isServerRunning: true, isListenerEnabled: true, listenerHealth: health) == .reachable,
        Comment(rawValue: "\(String(describing: health)) should not read as a failed listener"))
    }
  }
}
