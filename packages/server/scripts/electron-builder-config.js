// NOTE: All paths are relative to the package.json that will be loading this configuration file.
// Making them relative to the scripts folder will break the commands
module.exports = {
    "productName": "BlueBubbles",
    "appId": "com.BlueBubbles.BlueBubbles-Server",
    "npmRebuild": true,
    "directories": {
        "output": "releases",
        "buildResources": "appResources"
    },
    "asar": true,
    "extraResources": [
        "appResources"
    ],
    "mac": {
        "category": "public.app-category.social-networking",
        "publish": [
            {
                "provider": "github",
                "repo": "bluebubbles-server",
                "owner": "BlueBubblesApp",
                "private": false,
                "channel": "latest",
                "releaseType": "draft",
                "vPrefixedTagName": true
            }
        ],
        // The DMG is for first installs. electron-updater installs from the zip on macOS, and building
        // it is what writes latest-mac.yml (plus the zip blockmaps) for the GitHub release.
        "target": [
            {
                "target": "dmg",
                "arch": [
                    "x64",
                    "arm64"
                ],
            },
            {
                "target": "zip",
                "arch": [
                    "x64",
                    "arm64"
                ],
            }
        ],
        "type": "distribution",
        "icon": "../../icons/macos/dock-icon.png",
        "darkModeSupport": true,
        "hardenedRuntime": true,
        // Credentials come from the environment: APPLE_KEYCHAIN_PROFILE (a `notarytool store-credentials`
        // profile, which carries the team ID) or APPLE_API_KEY + APPLE_API_KEY_ID + APPLE_API_ISSUER.
        // Don't switch this to { teamId }: @electron/notarize 2.2.1 treats teamId as a password
        // credential and rejects it alongside a keychain profile or API key. With no credentials set,
        // electron-builder skips notarization with a warning and the build still signs.
        "notarize": true,
        "entitlements": "./scripts/entitlements.mac.plist",
        "entitlementsInherit": "./scripts/entitlements.mac.plist",
        "extendInfo": {
            "NSContactsUsageDescription": "BlueBubbles needs access to your Contacts",
            "NSAppleEventsUsageDescription": "BlueBubbles needs access to run AppleScripts",
            "NSSystemAdministrationUsageDescription": "BlueBubbles needs access to manage your system",
        },
        "gatekeeperAssess": false,
        // node-mac-permissions hard-links Speech.framework and CGPreflight/RequestScreenCaptureAccess,
        // all new in 10.15, so the server can't start on anything older (Electron 25 alone would allow 10.13).
        // Apple Silicon is 11.0 regardless. Bundled proxies need more: ngrok 11.0, zrok 14.0, cloudflared 15.0.
        "minimumSystemVersion": "10.15.0",
        "signIgnore": [
            "ngrok$",
            "zrok$",
            "cloudflared$"
        ],
    },
    "dmg": {
        "sign": false,
        "writeUpdateInfo": false
    },
    // "afterSign": "./scripts/notarize.js"
};
