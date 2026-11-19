const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require('typescript');
const { DataSource, EntitySchema } = require('typeorm');

const filename = path.resolve(__dirname, '../src/server/databases/imessage/index.ts');
const compiled = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;
const guid = '12345678-1234-1234-1234-123456789ABC';
const body = { attributedBody: [{ runs: [
    { attributes: { __kIMFileTransferGUIDAttributeName: guid } },
    { attributes: { __kIMFileTransferGUIDAttributeName: guid } }
] }] };

// Evaluate the real repository without loading Electron or the app's native modules.
function repository(highSierra = true, entities = {}) {
    const mod = { exports: {} };
    const dependency = name => {
        if (name.endsWith('/Loggable')) return { Loggable: class {} };
        if (name.endsWith('/env')) return { isMinHighSierra: highSierra };
        if (name.endsWith('/entity/Attachment')) return { Attachment: entities.Attachment };
        if (name.endsWith('/entity/Message')) return { Message: entities.Message };
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

function messageWithReferences(references, attachments = []) {
    return {
        attributedBody: [{ runs: references.map(reference => ({
            attributes: { __kIMFileTransferGUIDAttributeName: reference }
        })) }],
        attachments
    };
}

function stubHydrationLookup(repo, resolve) {
    repo.getAttachmentsForHydration = async references => {
        return new Map(Array.from(references, reference => [reference, resolve(reference)]));
    };
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

async function withSqliteRepository(highSierra, rows, test) {
    const primaryKey = { type: Number, primary: true, generated: true };
    const Attachment = new EntitySchema({
        name: 'Attachment',
        tableName: 'attachment',
        columns: {
            ROWID: primaryKey,
            guid: { type: String },
            ...(highSierra ? { originalGuid: { name: 'original_guid', type: String, nullable: true } } : {})
        }
    });
    const Handle = new EntitySchema({
        name: 'Handle',
        tableName: 'handle',
        columns: { ROWID: primaryKey }
    });
    const Message = new EntitySchema({
        name: 'Message',
        tableName: 'message',
        // The JSON column stands in for a body already decoded by BlueBubbles.
        columns: {
            ROWID: primaryKey,
            guid: { type: String },
            dateCreated: { name: 'date', type: Number },
            attributedBody: { type: 'simple-json' }
        },
        relations: {
            handle: { type: 'many-to-one', target: 'Handle', joinColumn: { name: 'handle_id' } },
            attachments: {
                type: 'many-to-many',
                target: 'Attachment',
                joinTable: {
                    name: 'message_attachment_join',
                    joinColumn: { name: 'message_id' },
                    inverseJoinColumn: { name: 'attachment_id' }
                }
            }
        }
    });
    const db = await new DataSource({
        type: 'sqljs',
        entities: [Attachment, Handle, Message],
        synchronize: true
    }).initialize();
    try {
        await db.getRepository(Attachment).insert(rows.map(row => ({ ...row })));
        const repo = repository(highSierra, { Attachment, Message });
        repo.db = db;
        await test(repo, db.getRepository(Message));
    } finally {
        await db.destroy();
    }
}

const attachmentIds = entry => entry.attachments.map(attachment => attachment.ROWID);

async function testSqliteHydration() {
    const joined = { ROWID: 1, guid: 'p:/' + guid };
    // The underscores in the requested native prefix must not act as SQL wildcards.
    const prefixDecoy = { ROWID: 2, guid: 'atX0Y' + guid };
    const exact = { ROWID: 3, guid: 'AT_0_' + guid };
    const uniqueSuffix = '00000000-0000-0000-0000-00000000000A';
    const tiedExact = 'p:/00000000-0000-0000-0000-00000000000B';
    const originalExact = 'p:/00000000-0000-0000-0000-00000000000C';
    const modernRows = [
        joined,
        prefixDecoy,
        exact,
        { ROWID: 4, guid: 'at_0_' + uniqueSuffix },
        { ROWID: 5, guid: tiedExact },
        { ROWID: 6, guid: '00000000-0000-0000-0000-00000000000D', originalGuid: tiedExact },
        { ROWID: 7, guid: 'at_0_' + originalExact.slice(-36) },
        { ROWID: 8, guid: '00000000-0000-0000-0000-00000000000E', originalGuid: originalExact }
    ];
    const exactRef = exact.guid.toLowerCase();

    await withSqliteRepository(true, modernRows, async (repo, messages) => {
        await messages.save([
            { guid: 'fully-joined', dateCreated: 10, ...messageWithReferences([joined.guid, exactRef], [joined, exact]) },
            { guid: 'mixed', dateCreated: 20, ...messageWithReferences([joined.guid, exactRef], [joined]) },
            { guid: 'missing-joins', dateCreated: 30, ...messageWithReferences([exactRef]) }
        ]);
        const joinsBefore = await repo.db.query('SELECT * FROM message_attachment_join ORDER BY message_id, attachment_id');
        assert.equal(joinsBefore.length, 3, 'the fixture deliberately omits joins');
        const [page, totalCount] = await repo.getMessages({});
        const byGuid = Object.fromEntries(page.map(entry => [entry.guid, entry]));
        assert.equal(totalCount, 3);
        assert.deepEqual(attachmentIds(byGuid['fully-joined']), [1, 3], 'keep the normally joined attachments');
        assert.deepEqual(attachmentIds(byGuid.mixed), [1, 3], 'keep the existing join and append the exact missing row');
        assert.deepEqual(attachmentIds(byGuid['missing-joins']), [3], 'resolve an exact row despite same-suffix decoys');
        assert.deepEqual(attachmentIds(await repo.getMessage('mixed', false, true)), [1, 3]);
        const updated = await repo.getUpdatedMessages({});
        assert.deepEqual(attachmentIds(updated.find(entry => entry.guid === 'mixed')), [1, 3]);
        const [withoutAttachments] = await repo.getMessages({ withAttachments: false });
        assert.equal(withoutAttachments.every(entry => !entry.attachments?.length), true);
        const joinsAfter = await repo.db.query('SELECT * FROM message_attachment_join ORDER BY message_id, attachment_id');
        assert.deepEqual(joinsAfter, joinsBefore, 'hydration only changes the returned attachment arrays');

        const suffixTie = messageWithReferences([guid]);
        const exactAfterTie = messageWithReferences([joined.guid.toLowerCase(), exactRef]);
        const suffix = messageWithReferences(['p:/' + uniqueSuffix.toLowerCase()]);
        const exactTie = messageWithReferences([tiedExact.toLowerCase()]);
        const exactViaOriginal = messageWithReferences([originalExact.toLowerCase()]);
        await repo.addMissingAttachmentsFromAttributedBody([suffixTie, exactAfterTie, suffix, exactTie, exactViaOriginal]);
        assert.deepEqual(attachmentIds(suffixTie), [], 'skip multiple rows matching only the UUID suffix');
        assert.deepEqual(attachmentIds(exactAfterTie), [1, 3], 'same-suffix references have separate cache entries');
        assert.deepEqual(attachmentIds(suffix), [4], 'accept a unique suffix match');
        assert.deepEqual(attachmentIds(exactTie), [], 'skip multiple exact matches across guid and original_guid');
        assert.deepEqual(attachmentIds(exactViaOriginal), [8], 'prefer one exact original_guid match over a suffix match');

        const manyReferences = Array.from({ length: 1_200 }, (_, index) => {
            return '00000000-0000-0000-0001-' + index.toString(16).padStart(12, '0');
        });
        const largeBatch = messageWithReferences([...manyReferences, exactRef]);
        const parameterCounts = [];
        const logQuery = repo.db.logger.logQuery;
        repo.db.logger.logQuery = (_query, parameters = []) => parameterCounts.push(parameters.length);
        try {
            await repo.addMissingAttachmentsFromAttributedBody([largeBatch]);
        } finally {
            repo.db.logger.logQuery = logQuery;
        }
        assert.deepEqual(attachmentIds(largeBatch), [3], 'resolve a match after the first chunk');
        assert.ok(parameterCounts.length > 1 && parameterCounts.length < 10, 'read candidates in a few chunks');
        assert.ok(parameterCounts.every(count => count <= 999), 'stay within the legacy SQLite variable limit');
    });

    await withSqliteRepository(false, [joined, exact, modernRows[3]], async repo => {
        const columns = await repo.db.query('PRAGMA table_info(attachment)');
        assert.equal(columns.some(column => column.name === 'original_guid'), false);
        const legacy = messageWithReferences([exactRef, 'p:/' + uniqueSuffix, guid]);
        await repo.addMissingAttachmentsFromAttributedBody([legacy]);
        assert.deepEqual(attachmentIds(legacy), [3, 4], 'resolve exact and unique suffix matches on the legacy schema');
    });
}

(async () => {
    const repo = repository();
    let queries = 0;
    stubHydrationLookup(repo, () => {
        queries++;
        return { ROWID: 42, guid: guid.toLowerCase() };
    });
    const a = message();
    const b = message();
    await repo.addMissingAttachmentsFromAttributedBody([a, b]);
    assert.equal(queries, 1, 'repeated references across messages use one lookup');
    assert.equal(a.attachments.length, 1);
    assert.equal(b.attachments.length, 1);
    await repo.addMissingAttachmentsFromAttributedBody([a, b]);
    assert.equal(queries, 1, 'rehydration neither duplicates nor refetches existing attachments');

    const prefixed = messageWithReferences(['P:/' + guid, 'p:/' + guid.toLowerCase()]);
    await repo.addMissingAttachmentsFromAttributedBody([prefixed]);
    assert.equal(prefixed.attachments.length, 1, 'valid prefixed UUID references remain supported');
    assert.equal(queries, 2, 'case variants of the same full reference share one lookup');

    const original = messageWithReferences(['P:/' + guid], [{
        ROWID: 42, guid: 'different', originalGuid: 'p:/' + guid.toLowerCase()
    }]);
    const beforeJoined = queries;
    await repo.addMissingAttachmentsFromAttributedBody([original]);
    assert.equal(original.attachments.length, 1);
    assert.equal(queries, beforeJoined, 'an already joined original GUID needs no fallback query');
    stubHydrationLookup(repo, () => null);
    const absent = { ...body };
    await repo.addMissingAttachmentsFromAttributedBody([absent]);
    assert.deepEqual(absent.attachments, []);
    repo.getAttachmentsForHydration = async () => { throw new Error('Unexpected attachment lookup'); };
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
            stubHydrationLookup(target, () => {
                lookups++;
                return { ROWID: 42, guid: guid.toLowerCase() };
            });
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
    empty.getAttachmentsForHydration = async () => { throw new Error('Unexpected missing-message lookup'); };
    assert.equal(await empty.getMessage('absent', true, true), null);

    // Cache misses are shared within one retrieval, but must not hide a row found by a later retrieval.
    const missing = repository();
    let missingLookups = 0;
    stubHydrationLookup(missing, () => { missingLookups++; return null; });
    const missingMessages = Array.from({ length: 100 }, message);
    await missing.addMissingAttachmentsFromAttributedBody(missingMessages);
    assert.equal(missingLookups, 1, 'a repeated missing GUID is looked up once per retrieval');
    assert.equal(missingMessages.every(entry => entry.attachments.length === 0), true);
    stubHydrationLookup(missing, () => {
        missingLookups++;
        return { ROWID: 42, guid: guid.toLowerCase() };
    });
    await missing.addMissingAttachmentsFromAttributedBody(missingMessages);
    assert.equal(missingLookups, 2, 'a new retrieval retries a previously missing GUID');
    assert.equal(missingMessages.every(entry => entry.attachments.length === 1), true);

    // Distinct references can resolve to the same row; ROWID deduplication must remain effective.
    const alias = repository();
    const secondGuid = 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE';
    let aliasLookups = 0;
    stubHydrationLookup(alias, value => { aliasLookups++; return { ROWID: 42, guid: value }; });
    const aliased = { attributedBody: [{ runs: [guid, secondGuid].map(value => ({
        attributes: { __kIMFileTransferGUIDAttributeName: value }
    })) }], attachments: [] };
    await alias.addMissingAttachmentsFromAttributedBody([aliased]);
    assert.equal(aliasLookups, 2);
    assert.equal(aliased.attachments.length, 1, 'two GUID aliases must not duplicate the same attachment row');

    // A large page should scale with unique references, not message or run count.
    const batch = repository();
    const batchSizes = [];
    batch.getAttachmentsForHydration = async references => {
        batchSizes.push(references.size);
        return new Map(Array.from(references, value => {
            return [value, { ROWID: Number.parseInt(value.slice(-12), 16), guid: value.slice(-36) }];
        }));
    };
    const batchMessages = Array.from({ length: 1_000 }, (_, index) => {
        const value = '00000000-0000-0000-0000-' + (index % 50 + 1).toString(16).padStart(12, '0');
        return messageWithReferences(['P:/' + value.toUpperCase(), 'p:/' + value]);
    });
    await batch.addMissingAttachmentsFromAttributedBody(batchMessages);
    assert.deepEqual(batchSizes, [50], '1,000 messages and 2,000 references give one batch of 50 unique references');
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

    await testSqliteHydration();
    console.log('PASS: attachment hydration with SQLite, retrieval opt-out, ambiguity handling and existing GUID lookup');
})().catch(error => { console.error(error); process.exitCode = 1; });
