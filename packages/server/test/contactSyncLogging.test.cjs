const assert = require("node:assert/strict");
const path = require("node:path");
const test = require("node:test");
const babel = require("@babel/core");

const transformModule = modulePath =>
    babel.transformFileSync(modulePath, {
        presets: [
            [require.resolve("@babel/preset-env"), { targets: { node: "20" }, modules: "commonjs" }],
            require.resolve("@babel/preset-typescript")
        ]
    }).code;

const contactErrorsPath = path.join(__dirname, "../src/server/api/interfaces/contactErrors.ts");
const contactErrorsModule = { exports: {} };
const loadContactErrors = new Function("module", "exports", "require", transformModule(contactErrorsPath));
loadContactErrors(contactErrorsModule, contactErrorsModule.exports, require);

const modulePath = path.join(__dirname, "../src/server/services/oauthService/contactSyncLogging.ts");
const loadedModule = { exports: {} };
const loadModule = new Function("module", "exports", "require", transformModule(modulePath));
const loadDependency = moduleId =>
    moduleId === "@server/api/interfaces/contactErrors" ? contactErrorsModule.exports : require(moduleId);
loadModule(loadedModule, loadedModule.exports, loadDependency);

const {
    formatGoogleContactSyncLogContext,
    formatGoogleContactSyncSummary,
    getGoogleContactSyncFailureReason,
    getGoogleContactSyncLogContext
} = loadedModule.exports;
const { CONTACT_ERROR_CODES } = contactErrorsModule.exports;

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

test("failure reasons consume only stable ContactInterface codes", () => {
    for (const code of Object.values(CONTACT_ERROR_CODES)) {
        assert.equal(getGoogleContactSyncFailureReason({ code }), code);
    }

    const privateMessage = "Database failed for private@example.com and +15555550123";
    const reason = getGoogleContactSyncFailureReason({ message: privateMessage });
    assert.equal(reason, "unknown-error");
    assert.equal(reason.includes(privateMessage), false);

    assert.equal(getGoogleContactSyncFailureReason({ code: "SQLITE_CONSTRAINT" }), "unknown-error");
    assert.equal(getGoogleContactSyncFailureReason({ code: "unsafe code with spaces" }), "unknown-error");
});
