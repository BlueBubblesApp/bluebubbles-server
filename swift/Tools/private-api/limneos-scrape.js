//  limneos-scrape.js
//  SUPERSEDED for macOS 15: `docs/headers/macos-15.6.1/` is a runtime dump now, and this
//  script's output was replaced wholesale. Kept for the NEXT release nobody has hardware
//  for — read the caveat below before trusting anything it produces.
//
//  Collects private headers a borrowed class-dump can supply, from
//  developer.limneos.net, for the classes this port actually messages.
//
//  WHY THIS EXISTS: `dump-headers.sh` is the real tool and its output supersedes anything
//  this produces — but it has to run ON a Sequoia machine, and nobody here has one. This is
//  the stopgap that made `macos-15.6/` exist in the first place; the original pass predated
//  `docs/SEQUOIA_COMPATIBILITY.md` §3, which found fifteen more classes the helpers message
//  and `hosts.conf` had never dumped. This collects those, plus the classes from §5.4 that
//  are only ever reached as return values.
//
//  READ docs/headers/README.md, "macOS 15.6 is a borrowed dump", before trusting the output.
//  It is read from the Mach-O in the dyld shared cache, so runtime-loaded categories do not
//  appear, and it is the NATIVE macOS framework rather than the /System/iOSSupport copy that
//  Messages.app actually loads.
//
//  HOW TO RUN
//    1. Open developer.limneos.net and solve one Turnstile challenge by hand.
//    2. Paste this whole file into the console and press enter.
//    3. If it stops early on Turnstile, solve another challenge and call BB.run() again —
//       it resumes from where it stopped. Progress survives reloads (localStorage).
//    4. When every target is collected it downloads `limneos-macos-15.6-part2.json`.
//       `BB.save()` downloads whatever has been collected so far, at any time.
//
//  Commands, once loaded:  BB.run()   BB.save()   BB.status()   BB.reset()
(() => {
  const VERSION = 'macos_15.6';
  const STORE = 'bb-limneos-' + VERSION;
  const DELAY_MS = 1000;

  // The fifteen from SEQUOIA_COMPATIBILITY.md §3 that are now in hosts.conf, plus the
  // classes from §5.4 that are only ever obtained as return values, plus the daemon
  // protocols. Framework attribution is not guesswork: each was read from the Objective-C
  // runtime with `probe.sh --platform macos`, because limneos indexes the NATIVE copies.
  const TARGETS = [
    // §3 — messaged by the helpers, never dumped before the 26.5.2 re-dump.
    { n: 'IMAccountController',                      f: 'IMCore.framework' },
    { n: 'IMChatHistoryController',                  f: 'IMCore.framework' },
    { n: 'IMDaemonController',                       f: 'IMCore.framework' },
    { n: 'IMFileTransferCenter',                     f: 'IMCore.framework' },
    { n: 'IMHandleAvailabilityManager',              f: 'IMCore.framework' },
    { n: 'IMMessage',                                f: 'IMCore.framework' },
    { n: 'IMNicknameController',                     f: 'IMCore.framework' },
    { n: 'IMPinnedConversationsController',          f: 'IMCore.framework' },
    { n: 'IMAggregateAttachmentMessagePartChatItem', f: 'IMCore.framework' },
    { n: 'IMDPersistentAttachmentController',        f: 'IMDPersistence.framework' },
    { n: 'IDSIDQueryController',                     f: 'IDS.framework' },

    // §5.4 — reached only as return values, so they never appear as a class NAME in the
    // helper source and the first sweep missed them.
    { n: 'IMMessageItem',  f: 'IMSharedUtilities.framework' },
    { n: 'IMFileTransfer', f: 'IMSharedUtilities.framework' },
    { n: 'IMAccount',      f: 'IMCore.framework' },
    { n: 'IMHandle',       f: 'IMCore.framework' },

    // The inbound-event path. `IMDaemonController.listener` returns the first of these on
    // macOS 26; it is what `addHandler:` and the `messageReceived:` callbacks live on, and
    // it is the most load-bearing undumped class in the port — typing indicators fail
    // silently when it moves, with nothing in any log.
    { n: '_IMLegacyDaemonListener', f: 'IMCore.framework' },
    { n: 'IMDaemonListener',        f: 'IMCore.framework' },

    // Protocols. `IMDaemonAnyProtocol` is where the nickname-sharing daemon call is
    // declared — the one that settled §5.1's argument type.
    { n: 'IMDaemonProtocol',         f: 'IMCore.framework', proto: true },
    { n: 'IMDaemonListenerProtocol', f: 'IMCore.framework', proto: true },
    { n: 'IMDaemonAnyProtocol',      f: 'IMCore.framework', proto: true },
  ];

  // NOT LISTED, deliberately — do not add them, they cannot work:
  //
  //   CKChatController  CKComposition  CKConversationList  CKMediaObjectManager
  //   CKConversation
  //
  // ChatKit has NO native macOS copy. It exists only under /System/iOSSupport, so it is not
  // in the native dyld shared cache limneos publishes, and `ChatKit.framework` is absent
  // from the 15.6 index entirely. Verified: `probe.sh --platform macos` reports all five
  // ABSENT while the Catalyst probe reports them present.
  //
  // That is the whole send path, and scraping cannot cover it. It needs either
  // `dump-headers.sh` on a Sequoia machine, or an iOS 18 dump as a rough proxy (Catalyst
  // ChatKit is built from the iOS one) — a proxy, not evidence.

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  const load = () => {
    try { return JSON.parse(localStorage.getItem(STORE)) || {}; } catch { return {}; }
  };
  const store = (o) => {
    try { localStorage.setItem(STORE, JSON.stringify(o)); }
    catch (e) { console.warn('localStorage full — progress is in memory only', e); }
  };

  const headerFile = (t) => t.n + (t.proto ? '-Protocol' : '') + '.h';
  const urlFor = (t) =>
    '/index.php?ios=' + VERSION +
    '&framework=' + encodeURIComponent(t.f) +
    '&header=' + encodeURIComponent(headerFile(t));

  // Three outcomes, not two. The earlier script treated "not gated" as "collected", which
  // silently banks a 404 body as though it were a header — and a truncated dump that looks
  // complete is exactly the failure docs/headers/README.md exists to prevent.
  function classify(html) {
    if (/Verify you are human|cf-turnstile|challenge-platform/i.test(html)) return 'gated';
    if (/@interface|@protocol/.test(html)) return 'ok';
    return 'missing';
  }

  const BB = {
    async run() {
      const out = load();
      const todo = TARGETS.filter((t) => !out[t.n] || out[t.n].status !== 'ok');
      if (!todo.length) {
        console.log('Everything already collected. Downloading.');
        return BB.save();
      }

      console.log(todo.length + ' to fetch (' + (TARGETS.length - todo.length) + ' already done).');
      let gated = 0;

      for (let i = 0; i < todo.length; i++) {
        const t = todo[i];
        const label = '[' + (i + 1) + '/' + todo.length + '] ' + headerFile(t);
        let html = '';
        try {
          html = await (await fetch(urlFor(t), { credentials: 'include' })).text();
        } catch (e) {
          console.warn(label + '  FETCH ERROR ' + e);
          await sleep(DELAY_MS);
          continue;
        }

        const status = classify(html);

        if (status === 'gated') {
          gated++;
          console.warn(label + '  GATED (' + gated + '/3)');
          if (gated >= 3) {
            console.error(
              'Gated three times running. Solve a challenge in this tab, then call ' +
              'BB.run() again — progress is saved.'
            );
            break;
          }
          // Back off rather than hammering. The check is per-page-view, and a burst
          // straight after one is what escalates it.
          await sleep(DELAY_MS * 5);
          continue;
        }

        gated = 0;
        out[t.n] = {
          framework: t.f,
          header: headerFile(t),
          status: status,
          html: status === 'ok' ? html : '',
        };
        store(out);
        console.log(
          status === 'ok'
            ? label + '  ok      (' + html.length + ' bytes)'
            : label + '  MISSING (no @interface/@protocol — wrong framework name, or not on 15.6)'
        );
        await sleep(DELAY_MS);
      }

      BB.status();
    },

    status() {
      const out = load();
      const ok = TARGETS.filter((t) => out[t.n] && out[t.n].status === 'ok').map((t) => t.n);
      const missing = TARGETS.filter((t) => out[t.n] && out[t.n].status === 'missing').map((t) => t.n);
      const todo = TARGETS.filter((t) => !out[t.n]).map((t) => t.n);
      console.log('collected ' + ok.length + '/' + TARGETS.length);
      if (missing.length) console.warn('not on 15.6 (or wrong framework):', missing.join(', '));
      if (todo.length) console.warn('still to fetch:', todo.join(', '));
      if (!todo.length) console.log('Done — BB.save() to download.');
      return { ok: ok, missing: missing, todo: todo };
    },

    save() {
      const out = load();
      // The `missing` entries ride along on purpose. "limneos does not have this" is an
      // answer worth keeping — it stops the next person re-running the scrape to find out.
      const payload = {
        version: VERSION,
        collectedAt: new Date().toISOString(),
        headers: out,
      };
      const a = document.createElement('a');
      a.href = URL.createObjectURL(
        new Blob([JSON.stringify(payload)], { type: 'application/json' })
      );
      a.download = 'limneos-' + VERSION + '-part2.json';
      document.body.appendChild(a);
      a.click();
      a.remove();
      console.log('saved ' + Object.keys(out).length + ' entries');
    },

    reset() {
      localStorage.removeItem(STORE);
      console.log('progress cleared');
    },
  };

  window.BB = BB;
  console.log('BB loaded. Commands: BB.run()  BB.save()  BB.status()  BB.reset()');
  return BB.run();
})();
