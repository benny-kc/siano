# Siano → siano-next rewrite — session handoff

> **Purpose of this file.** It is a handoff note written at the end of a planning
> session so a *fresh* Claude session can continue with zero context loss. It lives
> on branch `claude/mobile-server-data-sync-n2y0xj` in `benny-kc/siano` (NOT merged to
> `main`, NOT on `claude/siano-dev`). Read it top to bottom, then resume at
> **"What the next session should do first."**

---

## 1. Goal

Rewrite Siano (currently Elixir/Phoenix LiveView, server-owns-all-state) as a
**local-first** app in a brand-new repo **`benny-kc/siano-next`**. We are NOT modifying
the existing Elixir app; `siano-next` is a clean start that keeps the *product idea*
(travellers as tokens, meals as cards, drag-to-split, live shared board, OCR bills) but
changes the architecture.

## 2. The architecture we agreed on (local-first, strong eventual consistency)

The user initially described "a highly-consistent distributed DB with a few central
nodes + many mobile leaf nodes, all logic in static HTML/CSS/JS on the client." The key
reframing we landed on:

- **Drop "highly consistent" (linearizable).** It's incompatible with "the phone is a
  database that accepts writes offline" (CAP). Adopt **local-first / strong eventual
  consistency**: every device writes to its local copy instantly; all copies converge
  once they can talk. Guarantee = "everyone who has seen the same set of operations
  computes the same balances, regardless of order."

### The recommended shape

```
  Phone A ──┐                    ┌── Phone D
  (full DB) │                    │  (full DB)
  Phone B ──┤◀──▶ Hub / Relay ◀──┤── Phone E
  (full DB) │   (durable log +   │  (full DB)
  Phone C ──┘    fan-out relay)  └── ...
   every leaf holds the COMPLETE trip; hub is just the always-on replica
```

### Three core design commitments

1. **Store operations, not rows (event sourcing).** Sync an append-only log of
   intent-ops, e.g.:
   ```
   {op: "add_meal", meal_id, by: deviceA, lamport: 42}
   {op: "set_amount", meal_id, cents: 4200, by: deviceA, lamport: 43}
   {op: "add_participant", meal_id, member_id, by: deviceB, lamport: 44}
   {op: "set_share", meal_id, member_id, cents: 1500, locked: true, by: deviceC, lamport: 45}
   ```
   Every device folds the log into current state with the **same pure reducer** (this is
   the existing `Splitter`/`Snapshot` math moved client-side). Benefits: trivial/robust
   sync ("here are the ops you're missing"), and **the log IS the backup** — any leaf can
   re-seed the hub; the hub is just the most-available replica, not the source of truth.
   This also solves the original backup/recovery concern that started this whole thread.

2. **Make money conflicts intentional, not automatic.** Do NOT grab a generic CRDT and
   let last-writer-wins silently edit money. Instead:
   - Grow-only / tombstoning **sets** (participants, meals, members) → OR-Set CRDT
     (add/remove commute cleanly). This is most of the data and is genuinely
     conflict-free.
   - **Scalar money fields** (meal amount, a locked share) → LWW by Lamport clock for the
     value, BUT if two ops were truly concurrent, keep both and surface a "⚠ two people
     set this at once — pick one" reconciliation chip. (Same philosophy as today's red
     `diff_cents` badge: surface the discrepancy, let humans reconcile. Never hide it.)
   - **Integer cents everywhere**, client and server. Never sync floats.

3. **The hub is a dumb, durable relay — not a brain.** Its only jobs: durably append
   every op, fan out to connected leaves, and hand a returning leaf the delta (or a
   compacted snapshot + tail). NO business logic on the hub — keeps "all logic in static
   files on the client" literally true. Two active-active hubs behind one shared log
   satisfies "one or two central points."

### Decisions table (with the picks we made)

| Decision | Pick for this app | Why |
|---|---|---|
| Sync/convergence | **Roll-your-own op-log** | Tiny domain; money needs custom merge. A full sync engine (ElectricSQL/PowerSync/Zero/Triplit/Jazz) drags in a server DB, fighting the "static client + dumb hub" goal. |
| On-device store | **IndexedDB via Dexie** | Store op-log + a cached folded snapshot. SQLite-wasm is heavier than needed. |
| Transport | **WebSocket to hub (v1)** | Simple, NAT-friendly. Add WebRTC peer-to-peer later if wanted. |
| Photos (OCR bills) | **Separate blob channel** | Log carries `photo_id` + OCR fields; bytes sync opportunistically, uploader seeds them, hub caches. (The "photo vault" idea, now native.) |
| Identity/trust | **Trip URL = capability; per-device keypair signs ops** | No accounts, no server user model (matches today). Signing gives tamper-evidence + authorship. |
| Hub count | **Two active-active behind one shared log** | Plenty for a trip-splitter; true mesh is overkill. |

### Honest cost to name to the user

This is a **rewrite, not a refactor**. All split logic moves to the client and we take on
sync/merge code LiveView gave for free. Worth it only if offline-use + loss-proofing are
real goals (they are, per the conversation).

## 3. What was already done in the setup session

- Created **`benny-kc/siano-next`** on GitHub — **public**, empty (no README/gitignore/
  license). It exists but is currently empty.
- In the local `benny-kc/siano` clone (this working dir): ran `git fetch --unshallow
  origin`, so **full history is present locally** (was a shallow clone before).
- Added a git remote: `siano-next → https://github.com/benny-kc/siano-next`.
- **Blocker hit:** the Claude GitHub App on `benny-kc` is installed on *selected repos*
  and has **read but not write** to `siano-next` (also can't create repos — that's why
  the user created it by hand). `git push siano-next origin/main:refs/heads/main`
  returns **403**. `git ls-remote siano-next` (read) succeeds.
- **User's plan:** grant the Claude GitHub App **write access** to `siano-next` (via
  https://github.com/settings/installations → Configure Claude → add `siano-next` or
  "All repositories" → Save), then start a NEW chat and ask a fresh session to continue.

## 4. What the next session should do first

**Preconditions to verify:** the user has (a) granted the Claude App write access to
`benny-kc/siano-next`, and (b) attached it to the session. If `siano-next` isn't in
scope, call `add_repo(owner="benny-kc", repo="siano-next", access="push")` first.

**Step A — seed `siano-next` with the current siano code as the reference base.**
The user chose "Copy of current siano" so the reusable logic + history carry over. From a
full (unshallow) clone of `benny-kc/siano`:
```
git remote add siano-next https://github.com/benny-kc/siano-next   # if not present
git fetch --unshallow origin                                        # if the clone is shallow
git push siano-next origin/main:refs/heads/main                     # seed default branch w/ full history
```
Then confirm `main` is the default branch on `siano-next` and the history landed. (Only
`main` was intended — the many stale `claude/*` branches were deliberately NOT copied to
keep the new repo clean. Push a specific branch only if the user asks.)

> Note: this handoff session could NOT do Step A because of the 403 write block above.
> If write access is now granted, do it as the first action.

**Step B — first real commits on `siano-next` (the rewrite starts here).**
Recommended order:
1. Commit an architecture doc (`docs/architecture.md`) — lift Section 2 of THIS file as
   the starting content, expand as needed.
2. Scaffold the static PWA + sync-hub skeleton:
   - **Client** (static, no build step ideally, or Vite): `index.html` + ESM modules —
     an op-log store over IndexedDB (Dexie), Lamport clock, the pure reducer
     (`state = fold(ops)`), a WebSocket sync client, and the board UI.
   - **Hub**: a small WebSocket server = durable append-only log + fan-out + delta-on-
     reconnect. Stack-agnostic (Node/Bun/Deno, or Elixir if they want to keep BEAM for
     just the relay). Confirm the hub language with the user — it's the one open stack
     choice; the client is deliberately plain HTML/CSS/JS.
3. Define the concrete operation set + per-field merge rules for bill-splitting (see
   Section 2, commitments 1 & 2).

**Reusable assets to port from the siano reference base** (pure, Phoenix-free logic —
translate to JS/TS for the client reducer):
- `lib/siano/trips/splitter.ex` — `even_split/2`, `custom_split/3`, `balances/2`,
  `settlements/1`. Integer-cent split math (locked shares honoured exactly, never
  clamped). This is the heart of the reducer.
- `lib/siano/trips/money.ex` — `parse`/`format`/`extract` (string↔cents, OCR price token).
- `lib/siano/ocr.ex` + `lib/siano/images.ex` — Tika/Tesseract OCR + upright orientation
  (stays server-side / in a service; the client just uploads + taps fields).
- `assets/js/hooks/*` + `assets/js/lib/*` — the board pan/zoom, drag-to-split gestures,
  photo pipeline. These are already client-side and largely portable.
- Read `CLAUDE.md` in the siano reference for the full domain rules (budgets as
  union-find connected components, per-person split vs per-budget balances, the
  locked-share "never clamp" rule, morphdom gotchas — some of which disappear in a
  non-LiveView client).

**Then:** confirm the hub stack choice with the user and proceed with the scaffold.

## 5. Key domain rules that MUST survive the rewrite (from CLAUDE.md)

- Money is always **integer cents**, client and server.
- Meals split **per person**, but balances/settlements are **per budget** (a budget =
  people pooling money, e.g. a couple; resolved as union-find connected components over
  `budget_id`).
- **Locked/custom shares are honoured exactly — never clamped or nudged.** Only unlocked
  participants absorb the remainder; any gap surfaces as `diff_cents` for humans to
  reconcile. (This was the bug behind two "a fixed share got silently edited" reports.)
- Removing a member must scrub every reference (participants, payer, locked shares,
  photo-field assignments, others' budget pointers).

---

_Handoff written at the end of a planning session. Next session: start at Section 4._
