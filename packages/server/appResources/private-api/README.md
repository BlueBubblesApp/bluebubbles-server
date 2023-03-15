# Signature Verification

The `macosXbundle.md5` files within this directory contain a single string that is the Bundle's MD5 hash. The hash is a hash of all the file MD5s within the bundle. You can verify the Bundle by running the following command in your macOS terminal. Replacing `/path/to/private/api/folder` with the path to the parent directory of `BlueBubblesHelper.bundle`:

`find -s /path/to/private/api/folder/BlueBubblesHelper.bundle -type f -exec md5 {} \; | md5`

**GitHub Release Reference**: https://github.com/BlueBubblesApp/BlueBubbles-Server-Helper/releases/tag/0.0.13

You can also check the current versions of these bundles by opening the `version.txt` file.