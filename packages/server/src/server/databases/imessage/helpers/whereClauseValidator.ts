import type { EntityMetadata } from "typeorm";
import type { DBWhereItem } from "@server/databases/imessage/types";

/**
 * Validates the `where` clauses that API clients send to the message query endpoints.
 *
 * Each `statement` is handed to TypeORM's `andWhere()` as a raw SQL fragment, so it cannot be passed
 * through as-is: a client could inject subqueries and read any table in the iMessage database
 * (GHSA / issue #862). Rather than dropping support for custom filters, every statement is parsed
 * against a small grammar that covers what clients actually send, e.g.:
 *
 *   message.text LIKE :term COLLATE NOCASE
 *   message.associated_message_guid IS NULL
 *   message.guid IN (:...guids)
 *   message.ROWID > :startRowId
 *   message.service = 'iMessage'
 *
 * Supported: comparisons (=, ==, !=, <>, <, <=, >, >=), IS [NOT], [NOT] LIKE / GLOB / IN / BETWEEN,
 * COLLATE, AND / OR / NOT and parentheses. Operands are limited to known columns of the joined
 * tables, named parameters, numbers and simple string literals. Function calls, subqueries,
 * comments, statement separators and unknown identifiers are all rejected.
 */

/**
 * Columns a client-supplied WHERE clause may reference, keyed by query alias.
 * Everything is stored lowercased because SQLite resolves identifiers case-insensitively.
 */
export type QueryableColumns = Map<string, Set<string>>;

export class WhereClauseError extends Error {}

const MAX_WHERE_ITEMS = 25;
const MAX_STATEMENT_LENGTH = 1000;
const MAX_NESTING_DEPTH = 8;

const COLLATIONS = new Set(["NOCASE", "BINARY", "RTRIM"]);
const PARAM_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;

type TokenType = "column" | "keyword" | "param" | "spread" | "number" | "string" | "operator" | "punct";
type Token = { type: TokenType; value: string };

// Order matters: the first pattern that matches at the current position wins
const TOKEN_PATTERNS: [TokenType | null, RegExp][] = [
    // SQLite's whitespace only. JS \s also matches Unicode spaces, which SQLite reads as identifier characters.
    [null, /^[ \t\n\f\r]+/],
    // No escaped quotes, and no colons (TypeORM substitutes `:name` even inside string literals)
    ["string", /^'[^':]*'/],
    ["number", /^-?\d+(\.\d+)?(?![A-Za-z0-9_.])/],
    ["spread", /^:\.\.\.[A-Za-z_][A-Za-z0-9_]*(?![A-Za-z0-9_.])/],
    ["param", /^:[A-Za-z_][A-Za-z0-9_]*(?![A-Za-z0-9_.])/],
    ["column", /^[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*(?![A-Za-z0-9_.])/],
    ["keyword", /^[A-Za-z_][A-Za-z0-9_]*(?![A-Za-z0-9_.])/],
    ["operator", /^(==|!=|<>|<=|>=|=|<|>)/],
    ["punct", /^[(),]/]
];

const isPlainObject = (value: unknown): value is Record<string, unknown> =>
    typeof value === "object" && value !== null && !Array.isArray(value);

const isScalar = (value: unknown): boolean =>
    value === null ||
    typeof value === "string" ||
    typeof value === "boolean" ||
    (typeof value === "number" && Number.isFinite(value));

const tokenize = (statement: string, label: string): Token[] => {
    const tokens: Token[] = [];
    let position = 0;
    while (position < statement.length) {
        const rest = statement.slice(position);
        const found = TOKEN_PATTERNS.map(([type, pattern]) => ({ type, match: pattern.exec(rest) })).find(
            ({ match }) => match != null
        );

        if (!found) {
            throw new WhereClauseError(`${label}: unsupported syntax at position ${position}`);
        }

        if (found.type) tokens.push({ type: found.type, value: found.match[0] });
        position += found.match[0].length;
    }

    return tokens;
};

/**
 * Recursive-descent parser for the supported grammar. It only checks that the statement is valid;
 * the original string is what gets passed on to TypeORM.
 */
class StatementParser {
    private position = 0;

    constructor(
        private readonly tokens: Token[],
        private readonly columns: QueryableColumns,
        private readonly references: Map<string, boolean>,
        private readonly label: string
    ) {}

    parse(): void {
        if (this.tokens.length === 0) throw this.error("statement is empty");
        this.parseExpression(0);
        if (this.peek()) throw this.unexpected();
    }

    private parseExpression(depth: number): void {
        this.parseConjunction(depth);
        while (this.acceptKeyword("OR")) this.parseConjunction(depth);
    }

    private parseConjunction(depth: number): void {
        this.parseFactor(depth);
        while (this.acceptKeyword("AND")) this.parseFactor(depth);
    }

    private parseFactor(depth: number): void {
        if (depth > MAX_NESTING_DEPTH) throw this.error("statement is nested too deeply");

        if (this.acceptKeyword("NOT")) return this.parseFactor(depth + 1);
        if (this.accept("punct", "(")) {
            this.parseExpression(depth + 1);
            this.expect("punct", ")");
            return;
        }

        this.parsePredicate();
    }

    private parsePredicate(): void {
        this.parseOperand();

        if (this.peek()?.type === "operator") {
            this.position++;
            this.parseOperand();
            return;
        }

        if (this.acceptKeyword("IS")) {
            this.acceptKeyword("NOT");
            if (!this.acceptKeyword("NULL")) this.parseOperand();
            return;
        }

        this.acceptKeyword("NOT");
        if (this.acceptKeyword("LIKE") || this.acceptKeyword("GLOB")) {
            this.parseOperand();
        } else if (this.acceptKeyword("IN")) {
            this.parseList();
        } else if (this.acceptKeyword("BETWEEN")) {
            this.parseOperand();
            this.expectKeyword("AND");
            this.parseOperand();
        } else {
            throw this.unexpected();
        }
    }

    private parseOperand(): void {
        const token = this.next();
        switch (token?.type) {
            case "column":
                this.checkColumn(token.value);
                break;
            case "param":
                this.addReference(token.value.slice(1), false);
                break;
            case "number":
            case "string":
                break;
            default:
                throw this.unexpected(token);
        }

        if (this.acceptKeyword("COLLATE")) {
            const collation = this.next();
            if (collation?.type !== "keyword" || !COLLATIONS.has(collation.value.toUpperCase())) {
                throw this.error(`unsupported collation "${collation?.value ?? ""}"`);
            }
        }
    }

    private parseList(): void {
        this.expect("punct", "(");

        if (this.peek()?.type === "spread") {
            this.addReference(this.next().value.slice(4), true);
        } else {
            do {
                const token = this.next();
                if (token?.type === "param") {
                    this.addReference(token.value.slice(1), false);
                } else if (token?.type !== "number" && token?.type !== "string") {
                    throw this.unexpected(token);
                }
            } while (this.accept("punct", ","));
        }

        this.expect("punct", ")");
    }

    private checkColumn(reference: string): void {
        const [alias, column] = reference.toLowerCase().split(".");
        if (!this.columns.get(alias)?.has(column)) {
            throw this.error(`"${reference}" is not a queryable column`);
        }
    }

    private addReference(name: string, isSpread: boolean): void {
        const existing = this.references.get(name);
        if (existing != null && existing !== isSpread) {
            throw this.error(`parameter "${name}" is used both as a list and as a single value`);
        }

        this.references.set(name, isSpread);
    }

    private peek(): Token | undefined {
        return this.tokens[this.position];
    }

    private next(): Token | undefined {
        return this.tokens[this.position++];
    }

    private accept(type: TokenType, value: string): boolean {
        const token = this.peek();
        if (token?.type !== type || token.value !== value) return false;
        this.position++;
        return true;
    }

    private acceptKeyword(keyword: string): boolean {
        const token = this.peek();
        if (token?.type !== "keyword" || token.value.toUpperCase() !== keyword) return false;
        this.position++;
        return true;
    }

    private expect(type: TokenType, value: string): void {
        if (!this.accept(type, value)) throw this.unexpected();
    }

    private expectKeyword(keyword: string): void {
        if (!this.acceptKeyword(keyword)) throw this.unexpected();
    }

    private unexpected(token: Token | undefined = this.peek()): WhereClauseError {
        return this.error(token ? `unexpected "${token.value}"` : "unexpected end of statement");
    }

    private error(message: string): WhereClauseError {
        return new WhereClauseError(`${this.label}: ${message}`);
    }
}

/**
 * Builds the column allowlist from the entity metadata of each query alias.
 * Both database names (e.g. `associated_message_guid`) and property names (e.g. `dateCreated`) are
 * accepted, matching what TypeORM resolves, along with relation names that map to a join column.
 */
export const buildQueryableColumns = (aliases: Record<string, EntityMetadata>): QueryableColumns => {
    const columns: QueryableColumns = new Map();
    for (const [alias, metadata] of Object.entries(aliases)) {
        const names = new Set<string>();
        for (const column of metadata.columns) {
            names.add(column.databaseName.toLowerCase());
            names.add(column.propertyName.toLowerCase());
        }

        for (const relation of metadata.relations) {
            if (relation.joinColumns.length > 0) names.add(relation.propertyPath.toLowerCase());
        }

        columns.set(alias.toLowerCase(), names);
    }

    return columns;
};

/**
 * Validates client-supplied where clauses, throwing a WhereClauseError describing the first problem.
 * Returns the clauses unchanged when they are valid.
 */
export const validateWhereClauses = (where: unknown, columns: QueryableColumns): DBWhereItem[] => {
    if (where == null) return [];
    if (!Array.isArray(where)) throw new WhereClauseError("where must be an array");
    if (where.length > MAX_WHERE_ITEMS) {
        throw new WhereClauseError(`where cannot have more than ${MAX_WHERE_ITEMS} items`);
    }

    // Parameters are shared across every clause in the query, so collect them all before checking references
    const args = new Map<string, unknown>();
    const references = new Map<string, boolean>();
    for (const [index, item] of where.entries()) {
        const label = `where[${index}]`;
        if (!isPlainObject(item)) throw new WhereClauseError(`${label} must be an object`);

        const { statement } = item;
        // Some JSON encoders (e.g. PHP's) write an empty map as [], which older servers accepted
        const itemArgs = Array.isArray(item.args) && item.args.length === 0 ? null : item.args;
        if (typeof statement !== "string") throw new WhereClauseError(`${label}.statement must be a string`);
        if (statement.length > MAX_STATEMENT_LENGTH) {
            throw new WhereClauseError(`${label}.statement cannot be longer than ${MAX_STATEMENT_LENGTH} characters`);
        }

        if (itemArgs != null && !isPlainObject(itemArgs)) {
            throw new WhereClauseError(`${label}.args must be an object`);
        }

        for (const [name, value] of Object.entries(itemArgs ?? {})) {
            if (!PARAM_NAME.test(name) || name.startsWith("__")) {
                throw new WhereClauseError(`${label}.args has an invalid parameter name "${name}"`);
            }

            if (!isScalar(value) && !(Array.isArray(value) && value.every(isScalar))) {
                throw new WhereClauseError(
                    `${label}.args.${name} must be a string, number, boolean, null, or a list of those`
                );
            }

            args.set(name, value);
        }

        new StatementParser(tokenize(statement, label), columns, references, label).parse();
    }

    for (const [name, isSpread] of references) {
        if (!args.has(name)) throw new WhereClauseError(`parameter "${name}" is not defined in args`);

        const isList = Array.isArray(args.get(name));
        if (isSpread && !isList) throw new WhereClauseError(`parameter "${name}" must be a list (used as :...${name})`);
        if (!isSpread && isList)
            throw new WhereClauseError(`parameter "${name}" is a list; reference it as :...${name}`);
    }

    return where as DBWhereItem[];
};
