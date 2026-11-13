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
    await repo.addMissingAttachmentsFromAttributedBody([original]);
    assert.equal(original.attachments.length, 1);
    repo.getAttachment = async () => null;
    const absent = { ...body };
    await repo.addMissingAttachmentsFromAttributedBody([absent]);
    assert.deepEqual(absent.attachments, []);
    repo.getAttachment = async () => { throw new Error('Unexpected attachment lookup'); };
    await repo.addMissingAttachmentsFromAttributedBody([
        { attributedBody: null },
        { attributedBody: [{ runs: [{ attributes: { __kIMFileTransferGUIDAttributeName: 17 } }] }] },
        { attributedBody: [{ runs: ['%', '_', 'not-a-guid'].map(guid => ({
            attributes: { __kIMFileTransferGUIDAttributeName: guid }
        })) }] }
    ]);

    // Exercise each public retrieval boundary, including opting out of attachments.
    for (const method of ['getMessage', 'getMessages', 'getUpdatedMessages']) {
        for (const withAttachments of [false, true]) {
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
            assert.equal(lookups, withAttachments ? 1 : 0, method + ' respects withAttachments');
            assert.equal(messages[0].attachments.length, withAttachments ? 1 : 0);
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
