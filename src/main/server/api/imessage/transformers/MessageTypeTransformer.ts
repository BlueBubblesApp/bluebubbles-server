import { ValueTransformer } from "typeorm";

export const ReactionIdToString: { [key: number]: string } = {
    2000: "love",
    2001: "like",
    2002: "dislike",
    2003: "laugh",
    2004: "emphasize",
    2005: "question"
};

export const ReactionStringToId: { [key: string]: number } = {
    love: 2000,
    like: 2001,
    dislike: 2002,
    laugh: 2003,
    emphasize: 2004,
    question: 2005
};

export const MessageTypeTransformer: ValueTransformer = {
    from: (dbValue) => ReactionIdToString[dbValue] || null,
    to: (entityValue) => ReactionStringToId[entityValue] || null
};
