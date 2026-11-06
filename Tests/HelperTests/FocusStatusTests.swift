//
//  What `GET /api/v1/handle/:guid/focus` answers for each availability IMCore reports.
//
//  The client shows "has notifications silenced" for any status other than "none", so a status
//  that is merely spelled differently silences every chat at once. Neither the parity diff nor
//  the helper's own tests can see that: the key and its type are right either way.
//

import BBPrivateAPIContract
import Testing

@Suite("Focus status wire values")
struct FocusStatusTests {

  @Test("only availability 2 is silenced")
  func onlyUnavailableIsSilenced() {
    #expect(FocusStatus.wireValue(availability: 2) == "silenced")
  }

  @Test(
    "everything else is exactly what the client reads as not silenced",
    arguments: [-1, 0, 1, 3])
  func everythingElseIsNone(availability: Int) {
    #expect(FocusStatus.wireValue(availability: availability) == "none")
  }
}
