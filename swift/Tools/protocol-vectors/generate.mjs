#!/usr/bin/env node
//
// Generates golden protocol vectors from the CANONICAL implementations.
//
// The Swift Engine.IO / Socket.IO server has to be wire-compatible with clients built
// against socket.io-parser and engine.io-parser. Reading the spec and hoping is not good
// enough — subtle framing mistakes are exactly the kind that pass a hand-written test and
// fail against a real client.
//
// So: encode a spread of packets with the real parsers, and commit the output as fixtures
// the Swift codec must reproduce byte for byte. Unlike the HTTP fixtures, these need no Mac
// and no running server, so they can gate CI from day one.
//
//   node generate.mjs --out ../../Tests/ProtocolTests/ProtocolFixtures
//
// Run `npm install socket.io-parser engine.io-parser` in this directory first.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));

async function load(name) {
  // Resolved from wherever the reference packages were installed.
  const candidates = [
    path.join(here, 'node_modules', name),
    name
  ];
  for (const candidate of candidates) {
    try {
      return await import(candidate);
    } catch {
      /* try the next */
    }
  }
  throw new Error(
    `Could not load ${name}. Run: npm install socket.io-parser engine.io-parser`
  );
}

const sioParser = await load('socket.io-parser');
const eioParser = await load('engine.io-parser');

// Socket.IO packet types, from the protocol spec.
const PacketType = {
  CONNECT: 0,
  DISCONNECT: 1,
  EVENT: 2,
  ACK: 3,
  CONNECT_ERROR: 4,
  BINARY_EVENT: 5,
  BINARY_ACK: 6
};

/**
 * Socket.IO packets covering what the server actually emits and receives.
 *
 * Weighted toward the server -> client broadcast path, since that is what the clients rely
 * on, but the inbound request/ack shapes are here too so the legacy socket command layer has
 * something to test against when it lands.
 */
const socketIOPackets = [
  { name: 'connect', packet: { type: PacketType.CONNECT, nsp: '/' } },
  {
    name: 'connect-with-sid',
    packet: { type: PacketType.CONNECT, nsp: '/', data: { sid: 'abc123' } }
  },
  { name: 'disconnect', packet: { type: PacketType.DISCONNECT, nsp: '/' } },

  // The broadcast events the server emits. Names must match server/events.ts exactly.
  {
    name: 'event-new-message',
    packet: {
      type: PacketType.EVENT,
      nsp: '/',
      data: ['new-message', { guid: 'A1B2C3D4-0000-0000-0000-000000000001', text: 'Hello' }]
    }
  },
  {
    name: 'event-updated-message',
    packet: {
      type: PacketType.EVENT,
      nsp: '/',
      data: ['updated-message', { guid: 'A1B2C3D4-0000-0000-0000-000000000002', dateRead: 1717243200000 }]
    }
  },
  {
    name: 'event-typing-indicator',
    packet: {
      type: PacketType.EVENT,
      nsp: '/',
      data: ['typing-indicator', { display: true, guid: 'iMessage;-;+12025550143' }]
    }
  },
  {
    name: 'event-chat-read-status-changed',
    packet: {
      type: PacketType.EVENT,
      nsp: '/',
      data: ['chat-read-status-changed', { chatGuid: 'iMessage;-;+12025550143', read: true }]
    }
  },
  {
    // Deliberately included: the server emits this as a JSON *string*, not an object,
    // for backwards compatibility. Encoding it as an object would break clients.
    name: 'event-incoming-facetime-string-payload',
    packet: {
      type: PacketType.EVENT,
      nsp: '/',
      data: ['incoming-facetime', JSON.stringify({ caller: 'Jane', timestamp: 1717243200000 })]
    }
  },
  {
    name: 'event-null-payload',
    packet: { type: PacketType.EVENT, nsp: '/', data: ['hello-world', null] }
  },
  {
    name: 'event-unicode-payload',
    packet: {
      type: PacketType.EVENT,
      nsp: '/',
      data: ['new-message', { text: 'emoji 🎉 accents éàü quote " backslash \\' }]
    }
  },
  {
    name: 'event-with-ack-id',
    packet: { type: PacketType.EVENT, nsp: '/', id: 17, data: ['get-server-metadata', {}] }
  },
  { name: 'ack', packet: { type: PacketType.ACK, nsp: '/', id: 17, data: [{ status: 200 }] } },
  {
    name: 'connect-error',
    packet: { type: PacketType.CONNECT_ERROR, nsp: '/', data: { message: 'Unauthorized' } }
  }
];

/** Engine.IO packets: the handshake and heartbeat framing under Socket.IO. */
const engineIOPackets = [
  {
    name: 'open-handshake',
    packet: {
      type: 'open',
      data: JSON.stringify({
        sid: 'abc123def456',
        upgrades: ['websocket'],
        // Must match the server's socketOpts exactly, or clients time out differently.
        pingInterval: 60000,
        pingTimeout: 120000,
        maxPayload: 100000000
      })
    }
  },
  { name: 'ping', packet: { type: 'ping' } },
  { name: 'pong', packet: { type: 'pong' } },
  { name: 'ping-probe', packet: { type: 'ping', data: 'probe' } },
  { name: 'pong-probe', packet: { type: 'pong', data: 'probe' } },
  { name: 'upgrade', packet: { type: 'upgrade' } },
  { name: 'noop', packet: { type: 'noop' } },
  { name: 'close', packet: { type: 'close' } },
  {
    name: 'message-event',
    packet: { type: 'message', data: '2["new-message",{"guid":"A1B2C3D4"}]' }
  }
];

function encodeSocketIO(packet) {
  const encoder = new sioParser.Encoder();
  // Returns an array: one string for text packets, string + buffers for binary.
  return encoder.encode(packet);
}

function encodeEngineIO(packet) {
  return new Promise((resolve) => {
    eioParser.encodePacket(packet, false, (encoded) => resolve(encoded));
  });
}

async function main() {
  const outIndex = process.argv.indexOf('--out');
  const outDir = outIndex !== -1 ? process.argv[outIndex + 1] : null;
  if (!outDir) {
    process.stderr.write('usage: node generate.mjs --out <dir>\n');
    process.exit(1);
  }

  const socketIO = socketIOPackets.map(({ name, packet }) => ({
    name,
    packet,
    // What the Swift encoder must produce.
    encoded: encodeSocketIO(packet)
  }));

  const engineIO = [];
  for (const { name, packet } of engineIOPackets) {
    engineIO.push({ name, packet, encoded: await encodeEngineIO(packet) });
  }

  // An Engine.IO payload is several packets joined by the record separator (0x1e).
  const payloadPackets = ['4hello', '2', '3'];
  const payload = payloadPackets.join('\x1e');

  const fixtures = {
    _README:
      'Generated by Tools/protocol-vectors/generate.mjs from socket.io-parser and ' +
      'engine.io-parser, the canonical implementations. The Swift codec must reproduce ' +
      '`encoded` exactly for each `packet`. Regenerate rather than hand-editing.',
    _generatedFrom: {
      'socket.io-parser': readVersion('socket.io-parser'),
      'engine.io-parser': readVersion('engine.io-parser')
    },
    socketIO,
    engineIO,
    engineIOPayload: {
      name: 'multi-packet-payload',
      packets: payloadPackets,
      separator: '\\x1e',
      encoded: payload
    }
  };

  fs.mkdirSync(outDir, { recursive: true });
  const file = path.join(outDir, 'socketio-vectors.json');
  fs.writeFileSync(file, JSON.stringify(fixtures, null, 2) + '\n');

  process.stdout.write(
    `wrote ${file}\n` +
      `  socket.io packets: ${socketIO.length}\n` +
      `  engine.io packets: ${engineIO.length}\n`
  );
}

function readVersion(pkg) {
  try {
    const manifest = path.join(here, 'node_modules', pkg, 'package.json');
    return JSON.parse(fs.readFileSync(manifest, 'utf8')).version;
  } catch {
    return 'unknown';
  }
}

await main();
