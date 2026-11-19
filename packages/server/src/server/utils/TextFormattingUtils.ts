import { TextFormatting, TextFormattingStyle } from "@server/api/types";

export const TEXT_FORMATTING_STYLES: TextFormattingStyle[] = [
    "bold",
    "italic",
    "underline",
    "strikethrough"
];

const allowedStyles = new Set<TextFormattingStyle>(TEXT_FORMATTING_STYLES);

export const hasTextFormatting = (formatting?: TextFormatting | null): boolean => {
    return Array.isArray(formatting) && formatting.length > 0;
};

export const validateTextFormatting = (formatting: TextFormatting, message: string): void => {
    if (!Array.isArray(formatting)) {
        throw new Error("textFormatting must be an array");
    }

    if (typeof message !== "string" || message.length === 0) {
        throw new Error("A non-empty 'message' is required when using textFormatting");
    }

    const messageLength = message.length;
    for (let i = 0; i < formatting.length; i++) {
        const range = formatting[i] as any;
        if (!range || typeof range !== "object" || Array.isArray(range)) {
            throw new Error(`textFormatting[${i}] must be an object`);
        }

        const start = range.start;
        const length = range.length;
        const styles = range.styles;

        if (!Number.isInteger(start) || start < 0) {
            throw new Error(`textFormatting[${i}].start must be an integer >= 0`);
        }

        if (!Number.isInteger(length) || length <= 0) {
            throw new Error(`textFormatting[${i}].length must be an integer > 0`);
        }

        if (start + length > messageLength) {
            throw new Error(`textFormatting[${i}] range exceeds message length`);
        }

        if (!Array.isArray(styles) || styles.length === 0) {
            throw new Error(`textFormatting[${i}].styles must be a non-empty array`);
        }

        for (const style of styles) {
            if (!allowedStyles.has(style)) {
                throw new Error(`textFormatting[${i}].styles contains unsupported value: ${style}`);
            }
        }
    }
};
