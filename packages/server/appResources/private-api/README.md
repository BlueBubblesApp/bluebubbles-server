# Signature Verification

The `<Type>Helper.md5` files within each macOS directory contain a single string that is the Bundle's MD5 hash, per the build type. The hash is a hash of all the file MD5s within the bundle, in the case of the bundle. You can verify the Bundle by running the following command in your macOS terminal. Replacing `/path/to/private/api/folder` with the path to the parent directory of `BlueBubblesHelper.bundle`:

`md5 /path/to/private/api/folder/BlueBubblesHelper.dylib`

**GitHub Release Reference**: https://github.com/BlueBubblesApp/BlueBubbles-Server-Helper/releases

You can also check the current versions of these bundles by opening the `version.txt` file.

## Find My helper artifact

`BlueBubblesFindMyHelper.dylib` is built from the companion
`bluebubbles-helper` Find My target. The server enables it on macOS 15 or later
only when both Private API and **Open FindMy App on Startup** are enabled.
On macOS 11 through 13, Friends requests use the Messages helper when that
Private API is available. macOS 14 retains its existing Find My app fallback.

The checked-in artifact is built from [Helper PR #66](https://github.com/BlueBubblesApp/bluebubbles-helper/pull/66),
source commit `e2313f8b5a46d73f62c32e5bd718f0c8563a684e`.

On macOS 15 or later, the Devices GET route reads the server's latest helper
snapshot without changing the Find My view. The explicit Devices refresh route
opens `findmy://devices`, waits for the dedicated helper, and reads the
app-owned FMIP device collection. It does not use Accessibility clicks,
keyboard events, visible-cell scraping, or fixed view-loading delays.

The artifact checksum must match its `.md5` file, it must contain `x86_64` and
`arm64` slices, and it must use `@rpath/BlueBubblesFindMyHelper.dylib` as its
install name. Every server build checks this contract through:

```sh
npm run verify:findmy-helper
```

Automation permission requests for Find My and System Events happen only when
the Find My integration is started or its Accessibility fallback is explicitly
used. Normal server startup does not prompt for unrelated Automation access.

## Find My availability

On macOS 15 and later, the Server checks the Find My helper separately from the
Messages connection. An enabled Find My integration gets one 30-second attempt,
including Automation permission preparation, to launch and register its helper.
A missing connection is reported as unavailable rather than continuously
relaunching Find My. The Private API status panel and authenticated
`GET /api/v1/icloud/findmy/status` route report the current state. After addressing
permissions or a launch failure, use the panel's **Retry Find My check** button
or `POST /api/v1/icloud/findmy/retry` to start another attempt.

The Server reports system security information as diagnostics. A Messages
connection or SIP observation alone does not establish that Find My is ready;
the Find My helper must actually register and remain connected. The Server does
not change system security settings.

The Friends GET route continues to return cached data while the helper is
unavailable. A Friends refresh requests a fresh response: it returns HTTP 503
when the required helper is unavailable, and it fails if the helper returns an
invalid response instead of silently treating cached data as a fresh success.
The cache is retained in either case. Earlier macOS versions retain their
existing Friends routing and fallback behavior.

The dedicated Friends helper returns `locations`, boolean `partial` and
`friendListTimedOut` fields, a `timedOutHandles` string array, and a nonnegative
integer `skippedFriends` count. A complete snapshot (`partial: false`) must
report no timeouts or skipped friends. A partial snapshot may conservatively
retain previously cached friends even when no individual timeout is listed.
The Server validates completion metadata, identifiable records, and duplicate
handles before changing the cache. A valid complete empty snapshot clears it;
valid partial snapshots merge without replacing newer cached locations. Older
Messages helpers retain support for responses without completion metadata.

Friends HTTP and socket payloads serialize `is_locating_in_progress` as a JSON
boolean, matching the released clients. Native helper `0`/`1` flags are
normalized at the Server boundary.

## Find My release smoke test

TCC Automation grants are tied to the signed application identity. Before a
release, test a normally signed package on a user account without an existing
BlueBubbles Automation grant:

1. Enable Private API and **Open FindMy App on Startup**.
2. Confirm macOS requests Find My and System Events Automation access for
   BlueBubbles.
3. Confirm the helper registers as `com.apple.findmy` and Find My can be hidden.
4. Call the Friends GET, refresh, and GET routes and verify that all three
   succeed without helper, framing, transaction, or permission errors.
5. On macOS 15 or later, confirm the Find My status is ready. Disable the Find
   My startup preference and confirm Messages remains connected. Re-enable it
   and confirm a new Find My availability check succeeds.
6. With the required Find My helper unavailable, confirm a Friends GET can
   still return its cache while a refresh returns HTTP 503. Retry the Find My
   check and verify that a valid fresh response, including an empty snapshot,
   succeeds after helper registration.
7. Call the Devices GET, refresh, and GET routes. Confirm the first GET does not
   switch Find My views and the refreshed response includes both online and
   offline devices without converting missing locations to `(0, 0)`.
