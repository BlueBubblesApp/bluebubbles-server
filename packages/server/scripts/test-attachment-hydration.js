const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require('typescript');

const filename = path.resolve(__dirname, '../src/server/databases/imessage/index.ts');
const compiled = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;
const guid = '12345678-1234-1234-1234-123456789ABC';
const body = { attributedBody: [{ runs: [
    { attributes: { __kIMFileTransferGUIDAttributeName: guid } },
    { attributes: { __kIMFileTransferGUIDAttributeName: guid } }
] }] };

// Evaluate the real repository without loading native modules or a database.
function repository(highSierra = true) {
    const mod = { exports: {} };
    const dependency = name => {
        if (name.endsWith('/Loggable')) return { Loggable: class {} };
        if (name.endsWith('/env')) return { isMinHighSierra: highSierra };
        if (name.endsWith('/helpers/utils')) {
            return { isNotEmpty: value => Array.isArray(value) ? value.length > 0 : value != null };
        }
        return {};
    };
    new Function('require', 'module', 'exports', compiled)(dependency, mod, mod.exports);
    return Object.create(mod.exports.MessageRepository.prototype);
}

function message() {
    return { ...body, attachments: [] };
}

function messageQuery(repo, messages) {
    let query;
    query = new Proxy({
        getOne: async () => messages[0] ?? null,
        getMany: async () => messages,
        getManyAndCount: async () => [messages, 7]
    }, { get: (target, key) => key in target ? target[key] : () => query });
    repo.db = { getRepository: () => ({ createQueryBuilder: () => query }) };
}

(async () => {
    const repo = repository();
    let queries = 0;
    repo.getAttachment = async () => {
        queries++;
        return { ROWID: 42, guid: guid.toLowerCase() };
    };
    const a = message();
    const b = message();
    await repo.addMissingAttachmentsFromAttributedBody([a, b]);
    assert.equal(queries, 1, 'repeated references across messages use one lookup');
    assert.equal(a.attachments.length, 1);
    assert.equal(b.attachments.length, 1);
    await repo.addMissingAttachmentsFromAttributedBody([a, b]);
    assert.equal(queries, 1, 'rehydration neither duplicates nor refetches existing attachments');

    const prefixed = { attributedBody: [{ runs: ['p:/' + guid, 'at_0_' + guid.toLowerCase()].map(value => ({
        attributes: { __kIMFileTransferGUIDAttributeName: value }
    })) }], attachments: [] };
    await repo.addMissingAttachmentsFromAttributedBody([prefixed]);
    assert.equal(prefixed.attachments.length, 1, 'valid prefixed UUID references remain supported');
    assert.equal(queries, 2, 'equivalent prefixed references share one lookup');

    const original = { ...body, attachments: [{
        ROWID: 42, guid: 'different', originalGuid: 'prefix-' + guid.toLowerCase()
    }] };
    const beforeJoined = queries;
    await repo.addMissingAttachmentsFromAttributedBody([original]);
    assert.equal(original.attachments.length, 1);
    assert.equal(queries, beforeJoined, 'an already joined original GUID needs no fallback query');
    repo.getAttachment = async () => null;
    const absent = { ...body };
    await repo.addMissingAttachmentsFromAttributedBody([absent]);
    assert.deepEqual(absent.attachments, []);
    repo.getAttachment = async () => { throw new Error('Unexpected attachment lookup'); };
    await repo.addMissingAttachmentsFromAttributedBody([
        { attributedBody: null },
        { attributedBody: [{ runs: [{ attributes: { __kIMFileTransferGUIDAttributeName: 17 } }] }] },
        { attributedBody: [{ runs: ['%', '_', 'not-a-guid', '\0' + guid, '%\0' + guid].map(guid => ({
            attributes: { __kIMFileTransferGUIDAttributeName: guid }
        })) }] }
    ]);

    // Exercise each public retrieval boundary, including opting out of attachments.
    for (const method of ['getMessage', 'getMessages', 'getUpdatedMessages']) {
        for (const withAttachments of [false, true, undefined]) {
            const shouldHydrate = withAttachments ?? (method !== 'getMessage');
            const target = repository();
            const messages = [message(), message()];
            messageQuery(target, messages);
            let lookups = 0;
            target.getAttachment = async () => {
                lookups++;
                return { ROWID: 42, guid: guid.toLowerCase() };
            };
            const result = method === 'getMessage'
                ? await target.getMessage('synthetic-message', true, withAttachments)
                : await target[method]({ withAttachments });
            assert.equal(lookups, shouldHydrate ? 1 : 0, method + ' preserves withAttachments and its default');
            assert.equal(messages[0].attachments.length, shouldHydrate ? 1 : 0);
            if (method === 'getMessage') assert.strictEqual(result, messages[0]);
            else if (method === 'getMessages') {
                assert.strictEqual(result[0], messages);
                assert.equal(result[1], 7, 'hydration preserves the total count');
            } else assert.strictEqual(result, messages);
        }
    }
    const empty = repository();
    messageQuery(empty, []);
    empty.getAttachment = async () => { throw new Error('Unexpected missing-message lookup'); };
    assert.equal(await empty.getMessage('absent', true, true), null);

    // Cache misses are shared within one retrieval, but must not hide a row found by a later retrieval.
    const missing = repository();
    let missingLookups = 0;
    missing.getAttachment = async () => { missingLookups++; return null; };
    const missingMessages = Array.from({ length: 100 }, message);
    await missing.addMissingAttachmentsFromAttributedBody(missingMessages);
    assert.equal(missingLookups, 1, 'a repeated missing GUID is looked up once per retrieval');
    assert.equal(missingMessages.every(entry => entry.attachments.length === 0), true);
    missing.getAttachment = async () => {
        missingLookups++;
        return { ROWID: 42, guid: guid.toLowerCase() };
    };
    await missing.addMissingAttachmentsFromAttributedBody(missingMessages);
    assert.equal(missingLookups, 2, 'a new retrieval retries a previously missing GUID');
    assert.equal(missingMessages.every(entry => entry.attachments.length === 1), true);

    // Distinct references can resolve to the same row; ROWID deduplication must remain effective.
    const alias = repository();
    const secondGuid = 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE';
    let aliasLookups = 0;
    alias.getAttachment = async value => { aliasLookups++; return { ROWID: 42, guid: value }; };
    const aliased = { attributedBody: [{ runs: [guid, secondGuid].map(value => ({
        attributes: { __kIMFileTransferGUIDAttributeName: value }
    })) }], attachments: [] };
    await alias.addMissingAttachmentsFromAttributedBody([aliased]);
    assert.equal(aliasLookups, 2);
    assert.equal(aliased.attachments.length, 1, 'two GUID aliases must not duplicate the same attachment row');

    // A large page should scale with unique references, not message or run count.
    const batch = repository();
    let batchLookups = 0;
    batch.getAttachment = async value => {
        batchLookups++;
        return { ROWID: Number.parseInt(value.slice(-12), 16), guid: value.slice(-36) };
    };
    const batchMessages = Array.from({ length: 1_000 }, (_, index) => {
        const value = '00000000-0000-0000-0000-' + (index % 50 + 1).toString(16).padStart(12, '0');
        return { attributedBody: [{ runs: ['p:/' + value.toUpperCase(), 'at_0_' + value].map(reference => ({
            attributes: { __kIMFileTransferGUIDAttributeName: reference }
        })) }], attachments: [] };
    });
    await batch.addMissingAttachmentsFromAttributedBody(batchMessages);
    assert.equal(batchLookups, 50, '1,000 messages and 2,000 references require only 50 lookups');
    assert.equal(batchMessages.every(entry => entry.attachments.length === 1), true);

    // Hydration must not alter the existing prefix stripping or identifier case.
    for (const highSierra of [false, true]) {
        const target = repository(highSierra);
        const inputs = [];
        let parameter;
        const attachment = { ROWID: 42, guid };
        const query = {
            where(_sql, args) { parameter = args.guid; inputs.push(parameter); return this; },
            orWhere(_sql, args) { parameter = args.guid; return this; },
            async getOne() { return parameter === '%' + guid ? attachment : null; }
        };
        target.db = { getRepository: () => ({ createQueryBuilder: () => query }) };
        assert.strictEqual(await target.getAttachment('p:/' + guid), attachment);
        assert.deepEqual(inputs, ['%p:/' + guid, '%' + guid]);
    }

    console.log('PASS: attachment hydration, retrieval opt-out, duplicate prevention and existing GUID lookup');
})().catch(error => { console.error(error); process.exitCode = 1; });
