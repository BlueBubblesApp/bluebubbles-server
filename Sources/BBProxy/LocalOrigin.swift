//  LocalOrigin
//  What a tunnel forwards to: this server, on loopback, in the scheme it actually serves.
//
//  The scheme FOLLOWS the server rather than being assumed. "Serve over HTTPS" on the
//  Connection page makes the local server speak TLS, and a tunnel pointed at `http://` then
//  forwards into a port that will not answer in plaintext: cloudflared retries for ever, and
//  ngrok and zrok report a tunnel that is up and reaches nothing. Each of the three had that
//  bug in turn, which is why the URL is built in one place.
//
//  Tailscale is not here: Serve forwards to `127.0.0.1` and spells TLS `https+insecure`, which
//  is its own vocabulary rather than a URL any other tunnel accepts (`TailscaleOptions`).

enum LocalOrigin {

  /// `https://localhost:<port>` when the server speaks TLS, `http://localhost:<port>` when not.
  static func url(port: Int, usesTLS: Bool) -> String {
    "\(usesTLS ? "https" : "http")://localhost:\(port)"
  }
}
