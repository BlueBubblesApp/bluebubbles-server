import assert from "node:assert/strict";
import test from "node:test";

import { buildFindMyRoster, normalizeFindMyHandle } from "../src/server/api/lib/findmy/FindMyFriendRoster";

const fixture = {
    myInfo: { emails: ["owner@example.com"] },
    contacts: {
        "person-dad": { displayName: "Dad" },
        "person-may": { displayName: "May" },
        "person-phone": { displayName: "Phone Friend" }
    },
    following: [
        {
            id: "person-dad",
            invitationAcceptedHandles: ["dad-current@example.com"],
            invitationFromHandles: ["owner@example.com"]
        },
        {
            id: "person-may",
            invitationAcceptedHandles: ["may-current@example.com"],
            invitationFromHandles: ["owner@example.com"]
        },
        {
            id: "person-phone",
            invitationAcceptedHandles: ["+1 (555) 555-0123"],
            invitationFromHandles: ["owner@example.com"]
        }
    ],
    followers: [
        {
            id: "person-dad",
            invitationAcceptedHandles: ["owner@example.com"],
            invitationFromHandles: ["dad-old@example.edu"]
        },
        {
            id: "person-may",
            invitationAcceptedHandles: ["owner@example.com"],
            invitationFromHandles: ["+186****2782"]
        },
        {
            id: "person-phone",
            invitationAcceptedHandles: ["owner@example.com"],
            invitationFromHandles: ["+15555550123"]
        }
    ],
    preferences: { favorites: [{ id: "person-may", order: 1 }, { id: "person-dad", order: 0 }] }
};

test("builds one authoritative identity from all of a friend's Apple handles", () => {
    const roster = buildFindMyRoster(fixture)!;

    assert.equal(roster.primaryHandles.get("person-dad"), "dad-current@example.com");
    assert.equal(roster.aliases.get("dad-current@example.com"), "person-dad");
    assert.equal(roster.aliases.get("dad-old@example.edu"), "person-dad");
    assert.equal(roster.aliases.get(normalizeFindMyHandle("+186****2782")), "person-may");
    assert.equal(roster.names.get("person-dad"), "Dad");
    assert.deepEqual([...roster.favorites], [["person-may", 1], ["person-dad", 0]]);
});

test("normalizes formatting variants of the same phone number", () => {
    assert.equal(normalizeFindMyHandle("+1 (555) 555-0123"), normalizeFindMyHandle("+15555550123"));
    const roster = buildFindMyRoster(fixture)!;
    assert.equal(roster.aliases.get(normalizeFindMyHandle("+15555550123")), "person-phone");
});

test("never treats the owner's address as a friend's alias", () => {
    const roster = buildFindMyRoster(fixture)!;
    assert.equal(roster.aliases.has("owner@example.com"), false);
});

test("drops an ambiguous handle instead of merging two people", () => {
    const data = structuredClone(fixture);
    data.followers[1].invitationFromHandles = ["shared@example.com"];
    data.followers[2].invitationFromHandles = ["shared@example.com"];
    const roster = buildFindMyRoster(data)!;
    assert.equal(roster.aliases.has("shared@example.com"), false);
});

test("returns null when Apple has no authoritative following list", () => {
    assert.equal(buildFindMyRoster({ contacts: {} }), null);
});
