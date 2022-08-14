export class AttributedBodyUtils {
    static extractText(attributedBody: NodeJS.Dict<any>): string | null {
        return attributedBody?.string;
    }
}