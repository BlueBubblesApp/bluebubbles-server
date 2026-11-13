import { ValueTransformer } from "typeorm";

export const ReactionIdToString: { [key: string]: string } = {
    0: null,
    1000: "sticker",
    2000: "love",
    2001: "like",
    2002: "dislike",
    2003: "laugh",
    2004: "emphasize",
    2005: "question",
    3000: "-love",
    3001: "-like",
    3002: "-dislike",
    3003: "-laugh",
    3004: "-emphasize",
    3005: "-question"
};

export const ReactionStringToId: { [key: string]: number } = {
    sticker: 1000,
    love: 2000,
    like: 2001,
    dislike: 2002,
    laugh: 2003,
    emphasize: 2004,
    question: 2005,
    "-love": 3000,
    "-like": 3001,
    "-dislike": 3002,
    "-laugh": 3003,
    "-emphasize": 3004,
    "-question": 3005
};

export const MessageTypeTransformer: ValueTransformer = {
    from: (dbValue: number) =>
        Object.keys(ReactionIdToString).includes(dbValue.toString())
            ? ReactionIdToString[dbValue.toString()]
            : dbValue.toString(),
    to: entityValue => ReactionStringToId[entityValue] ?? 0
};
