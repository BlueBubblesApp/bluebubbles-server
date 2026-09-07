//  NonJSONResponses
//  The routes that do not answer with the envelope.
//
//  Most of the API returns `{status, message, data?}`, and the emitter assumes it. Two kinds
//  of route do not, and describing them as though they did is worse than saying nothing: a
//  generated client would try to JSON-decode a JPEG, and a reader would be told to expect a
//  `200` from a route that sends `201`.
//
//  Both lists are derived from what the handler RETURNS — `RouteResult.file`/`.bytes` for a
//  body that is bytes, `.noData` for the 201 — rather than guessed from the path. That is the
//  same source the router uses to build the response, so the two cannot disagree.
//
//  See docs/api/README.md § What the document does and does not describe.

import BBHTTPAPI

public enum NonJSONResponses {

  /// Routes whose 200 body is bytes, and what they send.
  ///
  /// The attachment routes serve whatever the file happens to be — a photo, a video, a voice
  /// memo — so they are `application/octet-stream`. The ones that always produce one kind
  /// say which kind, because a viewer can preview an image and cannot preview "some bytes".
  public static let binary: [HandlerID: (contentType: String, description: String)] = [
    .attachmentDownload: (
      "application/octet-stream",
      "The attachment's bytes. The actual Content-Type is the attachment's own — an image, "
        + "a video, a voice memo — and is set per response. HEIC and CAF are converted "
        + "unless `?original` is set."
    ),
    .attachmentForceDownload: (
      "application/octet-stream",
      "The attachment's bytes, after asking iCloud to re-download a purged file. Waits for "
        + "the transfer, so this can take a while on a large attachment."
    ),
    .attachmentDownloadLive: (
      "application/octet-stream",
      "The Live Photo's paired video component, as bytes."
    ),
    .attachmentBlurhash: (
      "image/jpeg",
      "A tiny JPEG rendering of the attachment's BlurHash, for a placeholder while the real "
        + "image loads."
    ),
    .chatGroupIcon: ("application/octet-stream", "The conversation's group photo, as bytes."),
    .chatBackground: (
      "application/octet-stream", "The conversation's wallpaper image, as bytes."
    ),
    .contactAvatar: (
      "application/octet-stream",
      "The contact's photo, as bytes. The same image the contact payload carries inline as "
        + "base64, without the base64."
    ),
    .messageEmbeddedMedia: (
      "application/octet-stream",
      "The media embedded in a digital-touch or handwritten message."
    ),
    .stickerImage: (
      "application/octet-stream",
      "The sticker's image bytes. The actual Content-Type is the representation's own — "
        + "`image/png` or `image/heic` — and is set per response from the UTI the store "
        + "holds for that representation. `?role=` picks which one; omitted serves the "
        + "preferred representation."
    ),
    .uiIndex: (
      "text/html",
      "The landing page. HTML, not JSON — this is the route a person opens in a browser to "
        + "check whether their tunnel is up."
    ),
  ]

  /// Routes whose success status is not 200.
  ///
  /// One route, and it is the reference server's behaviour rather than a choice: `.noData`
  /// answers 201, and the parity harness asserts it. Documenting it as 200 would make a
  /// strict client treat a correct response as a failure.
  public static let alternateSuccess: [HandlerID: (status: Int, description: String)] = [
    .facetimeLeave: (
      201,
      "Left the call. Answers **201**, not 200, and carries no body — inherited from the "
        + "reference server and asserted by the parity harness."
    )
  ]
}
