# 🧳 Siano

**Aplikacja do dzielenia się kosztami i śledzenia ich** — a playful, real-time
web app for a group of travellers who share costs on a trip (lunches, taxis,
hotels…). One person pays, everyone else gets their fair share automatically
tracked, and the app tells you who owes whom.

Built with **Elixir + Phoenix LiveView**. Each trip is a live `GenServer`, so
the interactive "game board" is fast and every browser on the same trip stays
in sync in real time — no database required.

## The idea

The screen is a little game board:

- **Travellers** are colourful tokens you can pick up.
- **Meals / restaurants** are cards on the table.
- **Drag a traveller onto a meal** to add them to that bill. 🍽️ Dragging one
  onto **empty board space** starts a **new meal** with them already in it.
- The board is a **pannable, zoomable canvas** — drag with **two fingers** to
  pan, **pinch** to zoom (trackpad: two-finger scroll to pan, ctrl/⌘+scroll to
  zoom). Single-finger drags still move cards and travellers.
- Type the **total**, tap whoever **paid** (💳), and the cost is split evenly
  across everyone on the card — down to the last cent.
- Need an uneven split? **Press and hold** a person's name/quota on a bill to
  set their **exact share**; everyone else's share re-adjusts so the bill total
  stays the same. A 📌 marks fixed shares; clear the field to go back to even.
- **Shared budgets:** by default one person = one budget, but people can pool
  their money (e.g. a couple). In Settings, set a traveller's budget to "shared
  with" someone. Meals still split **per person** (a 4-way meal divides by 4),
  but **balances and settle-up are tracked between budgets** — the couple owes
  or is owed a single combined amount, paid by either of them.
- The sidebar shows each traveller's running **balance**, a suggested
  **"settle up"** plan (who pays whom), and a **personal ledger** once you pick
  who you are.
- Attach **bill photos** (📷 on the card): they're rescaled on your device,
  uploaded to the server, and shown as small windows next to the meal. Photos
  travel with the meal — they close when you close the card and reappear when
  you reopen the bill from history.
- Uploaded bill photos are **OCR'd for prices** via an Apache Tika server
  (hOCR). Recognised amounts get clickable bordered overlays on the photo. Point
  the app at Tika with the `TIKA_URL` env var (default `http://localhost:9998`);
  the Tika image must have Tesseract OCR enabled.
- Closing a meal card (✕) never deletes it — every bill is kept in **Bills
  history** (the 🧾 button on the total). Tap any bill there to bring it back
  onto the board, ready to edit. Costs are always preserved and tracked.
- **Swipe gestures** (touch): swipe in from the **left** edge to open Bills,
  from the **right** edge to open Settings; swipe back to close.

### The lunch example from the brief

> One person pays for the whole lunch. The app counts how many people were on
> that lunch, divides the cost, and assigns an individual share to everyone so
> they can track it.

That is exactly what a meal card does. Put €30 on a "Lunch" card, drop Ala,
Bartek and Celina on it, tap Ala as the payer → Ala is owed €20, Bartek and
Celina each owe €10, and the settle-up list says "Bartek → Ala €10" and
"Celina → Ala €10".

## Architecture

```
Browser (LiveView + JS drag&drop hooks)
        │  events: drop_on_meal, set_amount, set_payer, move_meal …
        ▼
SianoWeb.TripLive ──────────────► Siano.Trips (context)
        ▲                                 │
        │  {:trip_updated, snapshot}      ▼
        │  via Phoenix.PubSub     Siano.Trips.TripServer  (one GenServer per trip)
        └─────────────────────────────────┤   started on demand under a
                                           │   DynamicSupervisor, found via a Registry
                                           ▼
                                 Siano.Trips.Splitter  (pure, tested money math)
                                 Siano.Trips.Money     (parse/format cents)
```

Key modules:

| Module | Responsibility |
| ------ | -------------- |
| `Siano.Trips.Splitter` | Pure fair-share math: even split (remainder-safe), balances, and greedy settlement suggestions. No process state — trivially testable. |
| `Siano.Trips.Money` | Parse user input (`"42.50"`, `"3,20"`) to integer **cents** and format back. All money is integer cents to avoid float errors. |
| `Siano.Trips.TripServer` | A `GenServer` holding one trip's live state (members, meals, participants). Every mutation broadcasts a fresh snapshot over PubSub. |
| `Siano.Trips` | The context/public API. Starts a trip process on demand and hides the GenServer from the web layer. |
| `Siano.Trips.Store` | Disk persistence via `:dets` (Erlang's built-in term store — no external DB). Each change is flushed to disk and re-loaded on start, so bills/costs survive server restarts (including the "pull & restart" deploy). |
| `SianoWeb.TripLive` | The LiveView game board. Translates UI events into context calls and re-renders on snapshots. |
| `assets/js/app.js` | Drag & drop hooks built on the **Pointer Events API** (works on touch *and* mouse — HTML5 drag-and-drop does not work on phones): `Traveller` (pick up a token, a ghost follows your finger, drop onto a meal), `MealCard` (pointer-drag the handle to reposition). |

State lives in a supervised process (fast, real-time) **and** is persisted to a
small on-disk `:dets` file, so there is no database to run — `mix phx.server` is
all you need, and nothing is lost when the server restarts. The data file lives
in `./siano_data/` by default (override with the `SIANO_DATA_DIR` env var).

## Running it locally

Requires **Elixir ~> 1.14** and **Erlang/OTP 25+**.

```bash
mix setup        # fetch deps + install & build assets (esbuild + tailwind)
mix phx.server   # start the server
```

Then open <http://localhost:4000> — you'll be dropped into a shareable `demo`
trip. Open the same URL in a second browser (or share it) and watch both boards
update live. Create a private board any time with the **✨ New trip** button.

> **Multiplayer tip:** the trip id is in the URL (`/t/<id>`). Anyone who opens
> the same id joins the same live board. Settings shows a **QR code** for the
> trip so others can scan to join — generated on-device (no external service),
> so it works offline / in the installed PWA.

Settings has a **"Your trips"** list (stored on your device in `localStorage`):
tap **Follow this trip** to add the one you're on, then switch between the trips
you follow. Only trips you explicitly follow are saved — not every one you open.

### Install as an app (PWA)

In a normal browser tab Siano goes **full-screen on your first tap** (browsers
don't allow it before a gesture), for a more app-like, roomier board.

For the real thing, it's a Progressive Web App: on a phone you can **Add to Home
Screen** and it launches **full-screen with no browser address bar** — more room
for the board. It ships a web app manifest (`display: fullscreen`), iOS/Android
meta tags, home-screen icons, and a minimal network-first service worker (which
also keeps the app installable and the shell available offline). Safe-area
padding keeps the UI clear of the notch and home indicator.

## Tests

The money logic and the trip server are covered by fast, dependency-free tests:

```bash
mix test
```

- `test/siano/splitter_test.exs` — the fair-share math (splits sum exactly,
  balances net to zero, settlements clear everyone).
- `test/siano/money_test.exs` — parsing/formatting cents.
- `test/siano/trips_test.exs` — the GenServer, including the lunch example.
- `test/siano_web/live/trip_live_test.exs` — the LiveView board & drop event.

## Notes for reviewers

This project was scaffolded in an environment where the Hex package repository
(`repo.hex.pm`) was **blocked by network policy**, so `mix deps.get` (and hence
a full `mix compile`) could not be run here. To compensate:

- The **pure domain logic and the `TripServer` GenServer were executed and
  verified** end-to-end with the standalone `elixir` runtime (Registry +
  GenServer are OTP stdlib; only `Phoenix.PubSub` was stubbed).
- Every Elixir source file was **syntax-checked** and `mix.exs` was validated up
  to dependency resolution.

Run `mix setup && mix test && mix phx.server` in an environment with normal Hex
access to build and play.
