// NOTE: All paths are relative to the package.json that will be loading this configuration file.
// Making them relative to the scripts folder will break the commands
module.exports = {
    "productName": "BlueBubbles",
    "appId": "com.BlueBubbles.BlueBubbles-Server",
    "npmRebuild": false,
    "directories": {
        "output": "release",
        "buildResources": "appResources"
    },
    "files": [
        "dist/",
        "node_modules/",
        "appResources/",
        "package.json"
    ],
    "asar": true,
    "asarUnpack": [
        "**/node_modules/ngrok/bin/**"
    ],
    "extraResources": [
        "**/appResources/**"
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
                "releaseType": "release"
            }
        ],
        "target": [
            {
                "target": "default",
                "arch": [
                    'x64',
                    'arm64'
                ]
            }
        ],
        "type": "distribution",
        "icon": "../../icons/regular/icon-512.png",
        "darkModeSupport": true,
        "hardenedRuntime": true,
        "entitlements": "./scripts/entitlements.mac.plist",
        "entitlementsInherit": "./scripts/entitlements.mac.plist",
        "extendInfo": {
            "NSContactsUsageDescription": "BlueBubbles needs access to your Contacts",
            "NSAppleEventsUsageDescription": "BlueBubbles needs access to run AppleScripts",
            "NSSystemAdministrationUsageDescription": "BlueBubbles needs access to manage your system",
        },
        "signIgnore": [
            "ngrok"
        ],
        "gatekeeperAssess": false,
        "minimumSystemVersion": "10.11.0"
    },
    "dmg": {
        "sign": false
    },
    "afterSign": "./scripts/notarize.js"
};
