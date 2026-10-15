// Run only in Electron Node mode against an in-memory database.
const assert = require("node:assert/strict");
const path = require("node:path");
const { DataSource } = require("typeorm");
const entities = require(path.resolve(process.argv[2]));
(async () => {
  const db = new DataSource({
    type: "better-sqlite3",
    database: ":memory:",
    entities: Object.values(entities),
    synchronize: true,
  });
  await db.initialize();
  const names = db.entityMetadatas.map((m) => m.targetName);
  assert.equal(
    new Set(names).size,
    names.length,
    "Minified entities must keep distinct runtime names"
  );
  const contacts = db.getRepository(entities.Contact),
    addresses = db.getRepository(entities.ContactAddress);
  const contact = await contacts.save(
    contacts.create({
      firstName: "Test",
      lastName: "Contact",
      displayName: "Test Contact",
      avatar: Buffer.from("test-photo"),
    })
  );
  contact.addresses = [];
  for (const [address, type] of [
    ["+12025550123", "phone"],
    ["test@example.org", "email"],
  ]) {
    const item = await addresses.save(addresses.create({ address, type }));
    contact.addresses.push(item);
    await contacts.save(contact);
  }
  const got = await contacts.findOne({
    where: { id: contact.id },
    relations: { addresses: true },
  });
  assert.equal(got.addresses.length, 2);
  assert.equal(got.avatar.toString(), "test-photo");
  await db.destroy();
  console.log("Production-minified contact/address persistence passed");
})().catch((e) => {
  console.error(e.message);
  process.exitCode = 1;
});
