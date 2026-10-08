import fs from "fs";

export type FindMyRoster = {
    /** Normalized phone/email -> Apple's opaque friend id. */
    aliases: Map<string, string>;
    /** Apple friend id -> the handle clients identify the friend by. */
    primaryHandles: Map<string, string>;
    /** Apple friend id -> contact name Find My shows for the friend. */
    names: Map<string, string>;
    /** Apple friend id -> position in the user's Find My favorites. */
    favorites: Map<string, number>;
};

/** Apple writes one number in several display formats, so compare phones by digits. */
export const normalizeFindMyHandle = (handle: string): string => {
    const value = handle.trim().toLowerCase();
    if (value.includes("@")) return value;
    const digits = value.replace(/\D/g, "");
    return digits.length > 0 ? `tel:${digits}` : value;
};

const strings = (value: unknown): string[] =>
    Array.isArray(value) ? value.filter((item): item is string => typeof item === "string" && item.trim().length > 0) : [];

/**
 * Builds the one-person-per-row roster used by Apple's Find My UI.
 *
 * A share is recorded in both directions. The friend's handles are the ones they
 * accepted my invitation on (`following`) and the ones they invited me from
 * (`followers`). The opposite fields hold my handles and must not become aliases.
 */
export const buildFindMyRoster = (data: any): FindMyRoster | null => {
    const following: any[] | null = Array.isArray(data?.following) ? data.following : null;
    if (!following) return null;
    const followers: any[] = Array.isArray(data?.followers) ? data.followers : [];

    const ownHandles = new Set(
        [
            ...strings(data?.myInfo?.emails),
            ...following.flatMap(friend => strings(friend?.invitationFromHandles)),
            ...followers.flatMap(friend => strings(friend?.invitationAcceptedHandles))
        ].map(normalizeFindMyHandle)
    );

    const handlesById = new Map<string, string[]>();
    for (const friend of following) {
        if (typeof friend?.id !== "string") continue;
        const accepted = strings(friend.invitationAcceptedHandles);
        const fallback = strings([friend.invitationFromHandle, friend.invitationSentToHandle]);
        handlesById.set(friend.id, accepted.length > 0 ? accepted : fallback);
    }
    for (const friend of followers) {
        const handles = typeof friend?.id === "string" ? handlesById.get(friend.id) : undefined;
        if (handles) handles.push(...strings(friend.invitationFromHandles));
    }

    const aliases = new Map<string, string>();
    const ambiguous = new Set<string>();
    const primaryHandles = new Map<string, string>();
    for (const [id, handles] of handlesById) {
        const friendHandles = handles.filter(handle => !ownHandles.has(normalizeFindMyHandle(handle)));
        if (friendHandles.length === 0) continue;
        primaryHandles.set(id, friendHandles[0]);
        for (const handle of friendHandles) {
            const key = normalizeFindMyHandle(handle);
            const existing = aliases.get(key);
            if (existing && existing !== id) ambiguous.add(key);
            aliases.set(key, id);
        }
    }
    for (const key of ambiguous) aliases.delete(key);

    const names = new Map<string, string>();
    const contacts = data?.contacts && typeof data.contacts === "object" ? data.contacts : {};
    for (const id of primaryHandles.keys()) {
        const name = contacts[id]?.displayName ?? contacts[id]?.shortName;
        if (typeof name === "string" && name.trim().length > 0) names.set(id, name);
    }

    const favorites = new Map<string, number>();
    for (const favorite of Array.isArray(data?.preferences?.favorites) ? data.preferences.favorites : []) {
        if (typeof favorite?.id === "string" && Number.isFinite(favorite?.order) && primaryHandles.has(favorite.id)) {
            favorites.set(favorite.id, favorite.order);
        }
    }

    return { aliases, primaryHandles, names, favorites };
};

/** Returns null if Apple's roster file is absent or temporarily unreadable. */
export const readFindMyRoster = (friendsPath: string): FindMyRoster | null => {
    try {
        return buildFindMyRoster(JSON.parse(fs.readFileSync(friendsPath, "utf8")));
    } catch {
        return null;
    }
};
