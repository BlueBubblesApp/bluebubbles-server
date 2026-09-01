# Commercial Licensing

The BlueBubbles Swift server (everything under `swift/`) is **source available**
under the [PolyForm Small Business License 1.0.0](LICENSE.md), plus an
additional permission for personal and household use.

It is not an OSI-approved open source license. You can read it, run it, change
it, and fork it. What you cannot do is use it for the benefit of a company above
a defined size without a commercial agreement with us.

## Scope: this applies to `swift/` only

**Everything outside the `swift/` directory is unaffected and remains under the
Apache License 2.0.**

The original Electron/TypeScript server in `packages/` — the server the vast
majority of people are running today — is Apache 2.0, stays Apache 2.0, and
keeps every freedom that license grants, including unrestricted commercial use.
Nothing on this page applies to it, retroactively or otherwise. We are not
relicensing existing code or revoking anyone's rights to it.

This page governs the new Swift server, and only the new Swift server.

> The plain-English summary below is a convenience. [`LICENSE.md`](LICENSE.md)
> is the binding document, and where the two differ, the license governs.

## The test is who you are, not what you do

This is the part that surprises people, so it is worth stating plainly.

Most source-available licenses restrict a *type of use* — usually reselling or
competing. This one restricts by the **size of the organization benefiting from
the software**. Your use is permitted if your company has:

- **fewer than 100 total individuals** working as employees and independent
  contractors, **and**
- **less than $1,000,000 USD in total revenue** in the prior tax year, measured
  in 2019 dollars and adjusted for inflation

Both conditions must hold. "Your company" includes parents, subsidiaries, and
entities under common control — a small subsidiary of a large corporation does
not qualify.

The consequence: **a company over that threshold needs a commercial license even
to self-host purely for its own internal use.** It does not matter that they are
not reselling it, not competing with us, and not shipping a product. If the
software benefits a company that size, it needs an agreement.

The revenue figure is indexed to the US Bureau of Labor Statistics CPI-U (all
urban consumers, US city average, all items, not seasonally adjusted,
1982–1984 = 100 reference base) from 2019. It is therefore meaningfully above
$1,000,000 in current dollars and rises each year. If your organization is near
the line, compute it against current BLS data rather than relying on the round
number, and feel free to ask us.

## What you can do for free

No permission, no payment, no email required:

- **Run it for yourself, your family, or your household.** Explicitly permitted
  by the additional grant in `LICENSE.md`, forever, regardless of anything else
  on this page. This is the overwhelming majority of BlueBubbles users and
  nothing here changes for you.
- **Run it for a company under the threshold**, including commercially. A
  fifteen-person business using it to talk to customers is fine.
- **Read, modify, and fork the source.** Publish your fork.
- **Redistribute it**, modified or not, provided you pass along the license (or
  its URL) and every `Required Notice:` line shipped with it.
- **Non-commercial education and research.**
- **Contribute back.** See [`CONTRIBUTING.md`](CONTRIBUTING.md).

You also get an explicit **patent license** and, if you ever fall out of
compliance, a **32-day cure period** after written notice before your rights end.

## What requires a commercial license

- **Any use for the benefit of a company at or above the size threshold**,
  including entirely internal use.
- **Offering hosted or managed BlueBubbles** to third parties, paid or as part
  of a paid plan.
- **Bundling the server into a product you sell** — an iMessage-on-Android app,
  a messaging gateway, a CRM integration.
- Building a **paid API or SaaS** on top of it.
- Reselling a **rebranded or white-labeled** version.

If you want to do any of these, we are genuinely open to it. That is what this
page is for.

## Attribution

If you redistribute the software or any part of it, you must pass along this
line, exactly as it appears in `LICENSE.md`:

```
Required Notice: Copyright 2026 Zachary Shames (BlueBubbles, https://bluebubbles.app)
```

This is a condition of the license, not a courtesy. Note also that the license
grants **no rights to the BlueBubbles name, logo, or marks** — identifying us as
the origin of the software is not the same as branding your product with our
name. Commercial agreements can grant a limited, revocable right to do so.

## Getting a commercial license

Email **bluebubblesapp@gmail.com** with:

1. Who you are, and the legal entity that would sign.
2. What you want to build, and how it reaches end users — or, for internal use,
   roughly how it will be deployed.
3. Rough scale — users, seats, or servers — and your pricing model, if any.
4. Your timeline.

Terms are negotiated per deal rather than published as a fixed price list,
because the arrangements differ a lot by scale. They typically cover:

- A grant scoped to the use you actually need.
- **Attribution** — visible credit to BlueBubbles in your product and materials,
  and a limited, revocable right to use the BlueBubbles name and marks.
- **Revenue share or a license fee**, as a percentage of associated revenue or a
  flat or tiered fee.
- Reporting and audit provisions matching the fee structure.
- Support and release-channel commitments, if you want them.
- Warranty, indemnity, and liability terms, which the license disclaims entirely.

We are far more interested in a working relationship than in enforcement. If you
are already doing something on this list, email us — we would rather paper it
than pursue it.

## This license does not expire

Unlike delayed-open licenses such as BUSL or FSL, the PolyForm Small Business
License has **no change date**. Releases do not convert to Apache 2.0 or any
other open source license after a set period. The terms above apply to each
version indefinitely.

## Why not Apache 2.0, like the rest of the repo?

The Electron server (`packages/`) is Apache 2.0 and **stays** Apache 2.0.
Nothing about its license changes.

The Swift server is new code, and we chose differently for it. BlueBubbles is
built and maintained by a small team, largely on unpaid time. Under a fully
permissive license, a company can take that work, deploy it at scale or sell it,
and contribute nothing back — and over the years, some have. Small businesses
and individuals were never the problem, so they keep everything for free. Larger
organizations getting real commercial value from the work are asked to come talk
to us.

We would rather be honest that this is source-available than stretch the term
"open source" to cover it.

## Questions

- **I self-host for my family. Anything change for me?** No. Permitted forever,
  at no cost, by the personal and household use grant.
- **My 20-person company runs it internally.** Free. You are under both prongs
  of the threshold.
- **My 4,000-person company runs it internally for our support team.** You need
  a commercial license, even though you are not reselling anything. Email us.
- **We are a 30-person subsidiary of a large corporation.** The threshold counts
  entities under common control, so you likely do not qualify. Email us.
- **I charge clients to set up their own BlueBubbles servers.** Your clients each
  need to qualify on their own, or hold their own commercial license. There is no
  blanket professional services exemption in this license — if this describes
  your business, talk to us and we will find something workable.
- **Can I still fork it on GitHub?** Yes. Forking, modifying, and publishing your
  fork are all permitted. Your fork carries the same license, and your fork's
  users are bound by the same threshold.
- **Can I accept donations for a free public instance?** Talk to us. It is a
  short conversation.
- **What about the Android/iOS clients?** Different repositories, different
  licenses. This page covers `swift/` only.

For anything not answered here, email **bluebubblesapp@gmail.com** and ask. We
would much rather answer the question up front than have you guess.
