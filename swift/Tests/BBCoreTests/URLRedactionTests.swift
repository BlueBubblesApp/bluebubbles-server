//  URLRedactionTests
//  A URL embedded in somebody else's prose is still a credential.
//
//  `Redaction.url` takes a URL and nothing else, which is right where a URL is what you have.
//  The case it missed is the one that actually leaked: a `URLError`'s description carries
//  `NSErrorFailingURLKey=https://…` with the whole query string in it, and that description
//  is stored on an alert as `underlyingDescription` and printed verbatim by
//  `redactedReport()` into the bundle people paste into chat and issue trackers.
//
//  Clients routinely put the server password in a webhook's query string, so that is a
//  password published by somebody trying to report a bug.

import Foundation
import Testing

@testable import BBCore

@Suite("URL redaction in text")
struct URLRedactionTests {

  @Test("A URL inside an error description has its secrets removed")
  func redactsInsideProse() {
    let text =
      "Error Domain=NSURLErrorDomain Code=-1004 \"Could not connect\" "
      + "UserInfo={NSErrorFailingURLKey=https://hooks.example.com/bb?password=hunter2hunter2}"
    let redacted = Redaction.urls(in: text)

    #expect(!redacted.contains("hunter2hunter2"), "the password survived: \(redacted)")
    // The rest of the message is what makes the report useful, so it has to stay.
    #expect(redacted.contains("NSURLErrorDomain"))
    #expect(redacted.contains("hooks.example.com"))
  }

  @Test("Every sensitive parameter name is covered", arguments: ["password", "guid", "token"])
  func coversEverySensitiveName(parameter: String) {
    let redacted = Redaction.urls(in: "failed: https://example.com/hook?\(parameter)=s3cret")
    #expect(!redacted.contains("s3cret"))
  }

  @Test("Text with no URL is returned unchanged")
  func leavesPlainTextAlone() {
    let text = "The helper is not connected."
    #expect(Redaction.urls(in: text) == text)
  }

  @Test("More than one URL in one string is handled")
  func handlesSeveral() {
    let redacted = Redaction.urls(
      in: "tried https://a.example/x?token=aaa then https://b.example/y?password=bbb")
    #expect(!redacted.contains("aaa"))
    #expect(!redacted.contains("bbb"))
  }

  @Test("A parameter that is not sensitive is left readable")
  func keepsHarmlessParameters() {
    // Over-redacting costs the person diagnosing the problem the information they needed.
    let redacted = Redaction.urls(in: "failed: https://example.com/hook?event=new-message")
    #expect(redacted.contains("event=new-message"))
  }

  /// The shapes the old rule returned completely unredacted.
  ///
  /// It blanked three named query values and kept the host and path, reasoning that those
  /// identify the endpoint. True of a URL somebody designed; false of the two providers this
  /// server is most often pointed at, where the secret IS a path component and there is no
  /// query string at all. And this reaches further than a debug line: `WebhookSink` logs the
  /// URL at warning after ten failures and puts it in the diagnostic bundle people paste into
  /// chat, so a webhook that went stale published its own live token to whoever was helping.
  ///
  /// NO REAL WEBHOOKS; these are the documented URL shapes, with invented secrets.
  @Test("A credential carried in the path does not survive")
  func credentialsInThePath() {
    let discord = Redaction.url("https://discord.com/api/webhooks/123456789/aLiveToken")
    #expect(!discord.contains("aLiveToken"), "a Discord webhook token is a path component")
    #expect(discord.contains("discord.com"), "the endpoint must still be identifiable")

    let slack = Redaction.url("https://hooks.slack.com/services/T000/B000/XXXXsecretXXXX")
    #expect(!slack.contains("XXXXsecretXXXX"))
    #expect(slack.contains("hooks.slack.com"))

    // One component is kept, because that is what says which endpoint this is.
    #expect(Redaction.url("https://example.com/api/a/b/c") == "https://example.com/api/...")
    // A single-component path is already minimal and is left alone.
    #expect(Redaction.url("https://example.com/hook") == "https://example.com/hook")
  }

  @Test("Userinfo and fragments are dropped outright")
  func userinfoAndFragment() {
    #expect(Redaction.url("https://user:hunter2@example.com/x") == "https://example.com/x")
    #expect(!Redaction.url("https://example.com/x#password=hunter2").contains("hunter2"))
  }

  @Test("A credential-shaped query name is matched by substring, not by exact spelling")
  func querySubstrings() {
    for name in ["access_token", "api_key", "apiKey", "auth", "X-Auth", "secret", "signature"] {
      let redacted = Redaction.url("https://example.com/x?\(name)=hunter2")
      #expect(
        !redacted.contains("hunter2"),
        Comment(rawValue: "`\(name)` carried its value through: \(redacted)"))
    }
  }

  @Test("A URL with nothing sensitive is left as it is")
  func harmlessURLsSurvive() {
    #expect(Redaction.url("https://example.com/") == "https://example.com/")
    #expect(Redaction.url("http://192.168.1.4:1234") == "http://192.168.1.4:1234")
    #expect(Redaction.url("https://example.com/x?page=2") == "https://example.com/x?page=2")
  }
}
