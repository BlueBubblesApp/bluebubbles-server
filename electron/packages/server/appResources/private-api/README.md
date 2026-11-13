# Signature Verification

The `<Type>Helper.md5` files within each macOS directory contain a single string that is the Bundle's MD5 hash, per the build type. The hash is a hash of all the file MD5s within the bundle, in the case of the bundle. You can verify the Bundle by running the following command in your macOS terminal. Replacing `/path/to/private/api/folder` with the path to the parent directory of `BlueBubblesHelper.bundle`:

`md5 /path/to/private/api/folder/BlueBubblesHelper.dylib`

**GitHub Release Reference**: https://github.com/BlueBubblesApp/BlueBubbles-Server-Helper/releases

You can also check the current versions of these bundles by opening the `version.txt` file.