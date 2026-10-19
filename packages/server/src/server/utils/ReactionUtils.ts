// Pure reaction protocol helpers shared by REST, Socket.IO and the private API.
const classicReactions = new Set(["love", "like", "dislike", "laugh", "emphasize", "question"]);
const emojiCodepoint = /\p{Extended_Pictographic}|\p{Regional_Indicator}{2}|[0-9#*]\uFE0F?\u20E3/u;

export type ParsedReaction = {
    reactionType: string;
    reactionEmoji?: string;
};

export function parseReaction(input: string): ParsedReaction {
    if (typeof input !== "string" || !input || Buffer.byteLength(input, "utf8") > 256) {
        throw new Error("A reaction must be a classic Tapback name or one Unicode emoji");
    }
    const remove = input.startsWith("-");
    const value = remove ? input.slice(1) : input;
    if (classicReactions.has(value)) return { reactionType: input };
    // Segmenter preserves flags, modifiers, keycaps and ZWJ families as one emoji.
    const Segmenter = (Intl as any).Segmenter;
    if (!Segmenter || Array.from(new Segmenter("en", { granularity: "grapheme" }).segment(value)).length !== 1 ||
        !emojiCodepoint.test(value) || /[\s\u0000-\u001f\u007f]/u.test(value)) {
        throw new Error("Custom reactions must contain exactly one Unicode emoji");
    }
    return { reactionType: remove ? "-emoji" : "emoji", reactionEmoji: value };
}

export function requireReactionSupport(input: string, helperSupportsEmoji: boolean): ParsedReaction {
    const parsed = parseReaction(input);
    if (parsed.reactionEmoji && !helperSupportsEmoji) {
        throw new Error("Custom emoji reactions require the matching emoji-capable helper on macOS Tahoe 26+");
    }
    return parsed;
}

export function serializeReactionType(kind: string, emoji: string): string {
    if (!emoji) return kind;
    if (kind === "emoji" || kind === "2006") return emoji;
    if (kind === "-emoji" || kind === "3006") return `-${emoji}`;
    return kind;
}
