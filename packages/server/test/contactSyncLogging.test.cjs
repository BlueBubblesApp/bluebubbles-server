const assert = require("node:assert/strict");
const path = require("node:path");
const test = require("node:test");
const babel = require("@babel/core");

const modulePath = path.join(__dirname, "../src/server/services/oauthService/contactSyncLogging.ts");
const transformed = babel.transformFileSync(modulePath, {
    presets: [
        [require.resolve("@babel/preset-env"), { targets: { node: "20" }, modules: "commonjs" }],
        require.resolve("@babel/preset-typescript")
    ]
});
const loadedModule = { exports: {} };
const loadModule = new Function("module", "exports", "require", transformed.code);
loadModule(loadedModule, loadedModule.exports, require);

const {
    formatGoogleContactSyncLogContext,
    formatGoogleContactSyncSummary,
    getGoogleContactSyncFailureReason,
    getGoogleContactSyncLogContext
} = loadedModule.exports;

test("contact sync context exposes field presence without provider values", () => {
    const contact = {
        resourceName: "people/private-resource-id",
        names: [
            {
                givenName: "PrivateGivenName",
                familyName: "PrivateFamilyName",
                displayName: "PrivateDisplayName"
            }
        ],
        phoneNumbers: [{ value: "+15555550123" }],
        emailAddresses: [{ value: "private@example.com" }],
        photos: [{ url: "https://example.com/private-avatar" }]
    };

    const context = getGoogleContactSyncLogContext(contact, 3);
    assert.deepEqual(context, {
        contactIndex: 3,
        hasResourceName: true,
        hasNameRecord: true,
        hasGivenName: true,
        hasFamilyName: true,
        hasDisplayName: true,
        hasPhoneNumbers: true,
        hasEmailAddresses: true,
        hasPhotos: true
    });

    const formatted = formatGoogleContactSyncLogContext(context);
    for (const privateValue of [
        contact.resourceName,
        contact.names[0].givenName,
        contact.names[0].familyName,
        contact.names[0].displayName,
        contact.phoneNumbers[0].value,
        contact.emailAddresses[0].value,
        contact.photos[0].url
    ]) {
        assert.equal(formatted.includes(privateValue), false);
    }
});

test("contact sync context treats empty provider fields as absent", () => {
    assert.deepEqual(
        getGoogleContactSyncLogContext(
            {
                resourceName: " ",
                names: [{ givenName: "", familyName: null, displayName: undefined }],
                phoneNumbers: [],
                emailAddresses: [],
                photos: []
            },
            1
        ),
        {
            contactIndex: 1,
            hasResourceName: false,
            hasNameRecord: true,
            hasGivenName: false,
            hasFamilyName: false,
            hasDisplayName: false,
            hasPhoneNumbers: false,
            hasEmailAddresses: false,
            hasPhotos: false
        }
    );
});

test("contact sync summary reports every result category", () => {
    assert.equal(
        formatGoogleContactSyncSummary({
            total: 7,
            succeeded: 4,
            skipped: 2,
            failed: 1
        }),
        "4 succeeded, 2 skipped, 1 failed (7 total)"
    );
});

test("failure reasons do not echo arbitrary exception text", () => {
    assert.equal(
        getGoogleContactSyncFailureReason({
            message: "To update an existing contact, you must provide one of the following: firstName"
        }),
        "missing-contact-identity"
    );

    const privateMessage = "Database failed for private@example.com and +15555550123";
    const reason = getGoogleContactSyncFailureReason({ message: privateMessage });
    assert.equal(reason, "unknown-error");
    assert.equal(reason.includes(privateMessage), false);

    assert.equal(getGoogleContactSyncFailureReason({ code: "SQLITE_CONSTRAINT" }), "error-code-SQLITE_CONSTRAINT");
    assert.equal(getGoogleContactSyncFailureReason({ code: "unsafe code with spaces" }), "unknown-error");
});
