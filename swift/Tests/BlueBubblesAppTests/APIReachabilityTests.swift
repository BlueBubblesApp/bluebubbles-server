//  APIReachabilityTests
//
//  `server_address` holds whatever the connection method last published, and nothing clears
//  it when the listener stops. Home and Guides read it to answer "what do I type into the
//  phone", so without this policy both pages went on handing out a URL for a server that
//  refuses every connection.

import Testing

@testable import BlueBubblesApp

@Suite("API reachability")
struct APIReachabilityTests {

  @Test("An address is only shown when something is listening")
  func onlyServingShowsTheAddress() {
    #expect(APIReachability.of(isServerRunning: true, isListenerEnabled: true) == .reachable)
    #expect(APIReachability.reachable.showsAddress)

    let listenerOff = APIReachability.of(isServerRunning: true, isListenerEnabled: false)
    #expect(listenerOff == .listenerSwitchedOff)
    #expect(!listenerOff.showsAddress)
  }

  /// A stopped server outranks the listener's own switch. Both are true, and "start the
  /// server" is the step that has to happen first, so it is the one worth saying.
  @Test("A stopped server is reported as stopped, whatever the listener's switch says")
  func stoppedOutranksSwitchedOff() {
    #expect(APIReachability.of(isServerRunning: false, isListenerEnabled: true) == .serverStopped)
    #expect(APIReachability.of(isServerRunning: false, isListenerEnabled: false) == .serverStopped)
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
}
