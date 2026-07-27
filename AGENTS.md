# AGENTS.md

This project's full agent & developer guide lives in **[`CLAUDE.md`](./CLAUDE.md)** —
read it before making changes. This file is a short pointer so any agent tooling that
looks for `AGENTS.md` finds the essentials.

## Siano in one line
A real-time, game-like **bill-splitting app for a group trip**: draggable traveller
tokens, meal/bill cards on a pannable board, live-shared over PubSub, with OCR of bill
photos. Elixir + Phoenix LiveView, **no database** (state in a GenServer per trip,
persisted to `:dets`), plain-ESM JS hooks, Tailwind.

## The five things to know before you touch anything
1. **You probably can't compile here.** The Hex registry is blocked in the agent
   sandbox — `mix compile`/`deps.get`/`phx.server`/tests won't run. Verify with
   `node --check` (JS), `Code.string_to_quoted` (Elixir syntax), and standalone
   `elixir *.exs` harnesses for pure logic. HEEx can't be compile-checked here — make
   sure every `phx-hook` element has an `id`.
2. **The server owns all state; the client is a view.** State changes go through
   `Siano.Trips` → `TripServer` (GenServer) → snapshot broadcast over PubSub → LiveView
   re-render. Money is always **integer cents**.
3. **morphdom strips anything a JS hook sets on an element** (inline style, added
   children, classes) on every re-render. Persist it: re-apply in `updated()` from a JS
   store, or use a `phx-update="ignore"` slot (with an `id`). Pan/zoom is stored as CSS
   vars on `:root`.
4. **Never use native `confirm()`/`prompt()`/`alert()`** — they exit full-screen. Use the
   in-page `Confirm` modal / `window.sianoConfirm`.
5. **Removing a traveller must scrub all references** to them (see `prune_meal_members`),
   or the persisted state crash-loops.

## Where things live
- `lib/siano/trips/trip_server.ex` — all trip state + mutations + snapshot (start here).
- `lib/siano/trips/{splitter,money,ocr,store,photos}.ex` — pure/util modules.
- `lib/siano_web/live/trip_live.{ex,html.heex}` — the LiveView + the entire UI.
- `assets/js/app.js` — all client behaviour (LiveView Hooks).
- `assets/css/app.css` — custom CSS (after `@tailwind` directives).

Full architecture, domain model, OCR pipeline, env vars, gotchas, and how-to recipes:
**see `CLAUDE.md`.**
