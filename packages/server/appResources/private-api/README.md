# Signature Verification

The `<Type>Helper.md5` files within each macOS directory contain a single string that is the Bundle's MD5 hash, per the build type. The hash is a hash of all the file MD5s within the bundle, in the case of the bundle. You can verify the Bundle by running the following command in your macOS terminal. Replacing `/path/to/private/api/folder` with the path to the parent directory of `BlueBubblesHelper.bundle`:

`md5 /path/to/private/api/folder/BlueBubblesHelper.dylib`

**GitHub Release Reference**: https://github.com/BlueBubblesApp/BlueBubbles-Server-Helper/releases

You can also check the current versions of these bundles by opening the `version.txt` file.

## Find My helper artifact

`BlueBubblesFindMyHelper.dylib` is built from the companion
`bluebubbles-helper` Find My target. The server enables it on macOS 15 or later
only when both Private API and **Open FindMy App on Startup** are enabled.

The artifact checksum must match its `.md5` file, it must contain `x86_64` and
`arm64` slices, and it must use `@rpath/BlueBubblesFindMyHelper.dylib` as its
install name. Every server build checks this contract through:

```sh
npm run verify:findmy-helper
```

Automation permission requests for Find My and System Events happen only when
the Find My integration is started or its Accessibility fallback is explicitly
used. Normal server startup does not prompt for unrelated Automation access.
