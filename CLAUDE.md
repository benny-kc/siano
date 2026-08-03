# Siano — agent & developer guide

Siano is a **real-time, game-like bill-splitting app for a group trip**. Travellers
are draggable tokens; meals/bills are cards on a pannable/zoomable board. You drag a
traveller onto a meal to add them to the split; costs are divided automatically and
everyone's running balance updates live. Bills can carry a **photo** whose prices are
recognised by OCR and assigned to travellers by tapping.

Everyone who opens the same trip URL (`/t/:id`) joins the **same live board** — state
is shared server-side and broadcast over PubSub.

> This file is the canonical guide. `AGENTS.md` is a short pointer to it. Read the
> **Working in this environment** section before making changes — the build
> constraints here are unusual.

---

## Working in this environment (READ FIRST)

**You very likely cannot run `mix compile`, `mix deps.get`, `mix phx.server`, or the
tests.** The package registry (`repo.hex.pm`) is blocked by network policy in the
agent sandbox, so dependencies can't be fetched and the app can't be compiled here.
Do **not** waste time trying; instead verify changes with the lightweight workflow
below. (The human runs the real app on their own machine + an Apache Tika server.)

### How to verify changes without compiling

- **JavaScript** (`assets/js/**/*.js`): `node --check <file>` (each hook/lib module is a
  standalone ES module, so check the one you changed — e.g. `node --check assets/js/hooks/photos.js`).
- **Elixir syntax**: `elixir -e 'File.read!("path.ex") |> Code.string_to_quoted() |> case do {:ok,_}->IO.puts("OK"); {:error,e}->IO.inspect(e) end'`
- **Pure logic** (splitting, OCR parsing, budget grouping, coordinate math): copy the
  function(s) into a standalone `.exs` harness in the scratchpad and run with
  `elixir file.exs`, asserting expected values. Modules with no Phoenix deps
  (`Siano.Trips.Money`, `Siano.Trips.Splitter`, `Siano.Ocr`) can be loaded directly
  with `Code.require_file/1`.
- **HEEx templates** can't be compile-checked here (that needs the Phoenix compiler).
  Eyeball tag balance carefully; the common failure is a `phx-hook` element missing an
  `id` (LiveView requires one) — that only surfaces at `mix compile` on the human's
  side. Double-check every new `phx-hook`/`phx-update="ignore"` element has a stable
  `id`.

### Deploying / running (on the human's machine)
- Local: `mix setup` then `mix phx.server` (http://localhost:4000).
- There is a **remote "Pull & restart" button** in Settings → it calls `:c.q()` to
  stop the BEAM; an external process manager is expected to `git pull` and relaunch.
  State survives because it's persisted to disk (see Persistence).

---

## Tech stack

- **Elixir ~> 1.20**, **Phoenix 1.7.24**, **Phoenix LiveView 0.20.17**, **Bandit** web server.
- **No database, no Ecto.** State lives in a GenServer per trip and is persisted to
  disk with **`:dets`** (Erlang stdlib). The app runs with nothing but `mix phx.server`.
- **Assets:** Tailwind 3.4.3 + esbuild (no Node build step beyond these; `assets/js` is
  plain ESM). PubSub via `Phoenix.PubSub`.
- **OCR:** an external **Apache Tika (`-full` image, with Tesseract + ImageMagick)**
  server, called over HTTP via `:httpc` (`:inets`). Not bundled.
- Deps in `mix.exs`: phoenix, phoenix_html, phoenix_live_view, esbuild, tailwind,
  jason, bandit, telemetry_*. `floki` (test only).

---

## Architecture & data flow

```
Browser (LiveView + JS hooks)  ──phx events──▶  SianoWeb.TripLive
        ▲                                              │ calls
        │ PubSub {:trip_updated, snapshot}             ▼
        └──────────────────────────────  Siano.Trips (context)
                                                       │ delegates
                                                       ▼
                                          Siano.Trips.TripServer  (GenServer, one per trip)
                                             ├─ snapshot/budgets: Siano.Trips.Snapshot
                                             ├─ OCR-field math:   Siano.Trips.Fields
                                             ├─ pure money math:  Siano.Trips.Splitter / Money
                                             ├─ persistence:      Siano.Trips.Store (:dets)
                                             └─ photos on disk:   Siano.Trips.Photos
                                                       ▲
                             Photo upload/OCR ─────────┘
                             SianoWeb.PhotoController → Siano.Ocr (Tika)
```

- **One GenServer per trip** (`Siano.Trips.TripServer`), addressed by trip id through a
  `Registry` (`:via` tuple), started on demand under a `DynamicSupervisor`
  (`Siano.Trips.TripSupervisor`). See `lib/siano/application.ex` for the supervision tree.
- Every state-changing `handle_call` ends with `reply_and_broadcast/1`, which:
  1. persists the full state to `:dets` (`Store.put`), then
  2. builds a **snapshot** (plain maps with all derived values) via `build_snapshot/1`, then
  3. broadcasts `{:trip_updated, snapshot}` on PubSub topic `"trip:<id>"`.
- `TripLive` subscribes to that topic on mount and re-renders on every snapshot, so all
  viewers of the same trip stay in sync. The LiveView never does money math — the
  snapshot already contains everything the template needs.
- **`Siano.Trips`** is the context (thin `defdelegate` pass-throughs). The web layer
  only ever talks to `Siano.Trips`, never the GenServer directly. `ensure_started/2`
  lazily boots a trip process (rehydrating from disk if present).

---

## Directory map — where things live

| Path | What |
|---|---|
| `lib/siano/trips/trip_server.ex` | **The heart.** The GenServer: all trip state + every mutation (`handle_call`), rehydrate/`normalize`, and broadcasting. ~710 lines. Start here. Delegates snapshot building to `Snapshot` and photo-field math to `Fields`. |
| `lib/siano/trips/snapshot.ex` | Pure: `build_snapshot/1` (the plain-map view LiveViews render) + budgets (`resolve_budgets`, `build_budgets`, `budget_id`), `decorate_meal`, `summarize_bill`, `expenses_from_meals`. No process state — testable on its own. |
| `lib/siano/trips/fields.ex` | Pure OCR-field helpers on a meal: `toggle_field`, `set_field_text`, `member_field_sum`, `merge_fields`, `dedup_fields`, `choose_candidate`, `prune_meal_members` (+ box geometry). |
| `lib/siano/trips.ex` | Context: `defdelegate`s + `ensure_started/2`, `get_snapshot/1`. |
| `lib/siano/trips/splitter.ex` | Pure cost-split math: `even_split/2`, `custom_split/3`, `balances/2`, `settlements/1`. Integer cents, sums exactly. |
| `lib/siano/trips/money.ex` | `parse/1` (string→cents), `format/1` (cents→string), `extract/1` (first price token out of OCR text). |
| `lib/siano/trips/store.ex` | `:dets` persistence GenServer. `get/1`, `put/2`, `all_ids/0`. |
| `lib/siano/trips/photos.ex` | Bill photo files on disk (save/save_bytes/delete/path). Path-traversal-safe ids. |
| `lib/siano/images.ex` | Server-side bill-photo orientation: `orient_upright/1` (best of four 90° rotations by OCR score, via ImageMagick). Graceful fallback if ImageMagick is absent. |
| `lib/siano/ocr.ex` | Tika/Tesseract OCR: `recognize/2`, `recognize_bytes/2`, `score_bytes/1`, `parse/1`, `dedup/1`. |
| `lib/siano_web/live/trip_live.ex` | LiveView: `mount`, `handle_params`, `handle_event`s, `handle_info`. |
| `lib/siano_web/live/trip_live.html.heex` | Thin composition: renders the `<Components.*/>` section components inside the `#trip` wrapper. |
| `lib/siano_web/live/trip_live/components.ex` | `SianoWeb.TripLive.Components`: `embed_templates "sections/*"` (one function component per UI section) + the template view helpers (`money`, `field_label_style`, balance labels). |
| `lib/siano_web/live/trip_live/sections/*.html.heex` | **The UI**, one file per section: `top_bar`, `board` (meal cards + photos), `dock`, `bills_drawer`, `settings`, `help`, `confirm`. |
| `lib/siano_web/controllers/photo_controller.ex` | Photo upload + OCR endpoints (`create` — straightens then stores, `ocr_region`, `show`). |
| `lib/siano_web/router.ex` | Routes. |
| `assets/js/app.js` | **Client entry point.** Imports the hooks, assembles the `Hooks` map, boots the LiveSocket, service worker + full-screen manager. Thin (~120 lines). |
| `assets/js/hooks/*.js` | **All client behaviour**, one concern per module: `pan_zoom`, `traveller`, `field_label`, `meal_card`, `gestures`, `photos` (upload pipeline + PhotoUpload/TopPhoto/BillPhoto), `drawers` (DrawerWatch + history), `trips` (Ledger + TripSwitcher), `dialogs` (QR + Confirm), `net_speed`, `misc` (LocalTime/Focus/LongPress). Each `export const <Hook> = {...}`. |
| `assets/js/lib/*.js` | Shared client state/util imported by hooks: `board` (`BoardView` pan/zoom), `net` (`NetMeter` + install), `selection` (`selectedMember`), `zorder` (card z-index). |
| `assets/css/app.css` | Custom CSS (after `@tailwind` directives). Animations, drag ghost, dock, placeholders. |
| `assets/tailwind.config.js` | Tailwind content globs + `phx-*-loading` variants. |
| `assets/vendor/qrcode.js` | Self-contained QR encoder (used by the `QR` hook). |
| `config/*.exs` | Standard Phoenix config. `runtime.exs` reads `PHX_HOST`/`PORT`/`SECRET_KEY_BASE`. |
| `priv/static/` | PWA manifest, icons, `service-worker.js`. |

---

## Domain model

### In-memory state (`TripServer` state map)
```
%{
  id, name, seq,                       # seq = monotonic id counter
  members:      %{member_id => member},
  member_order: [member_id, ...],      # display order
  meals:        %{meal_id => meal},
  meal_order:   [meal_id, ...]
}
member = %{id, name, color, initials, budget_id}   # budget_id points at whoever they pool with
meal   = %{id, name, emoji, amount_cents, payer_id, participant_ids,
           locked_shares: %{member_id => cents},   # custom shares; empty = even split
           inserted_at,                             # unix seconds UTC
           photos: [%{id, fields: [%{text, x, y, w, h, member_id?}]}],  # x/y/w/h are 0..1
           open, x, y}                              # open = card visible; x/y = board coords (px)
```

### Snapshot (what the LiveView renders — `build_snapshot/1`)
Plain maps with **all derived values precomputed**: each member carries their budget's
`balance_cents`, `budget_name`, `budget_solo`, `budget_partner_id`, `budget_partner_names`;
each open meal carries decorated `participants` (with `share_cents`, `is_payer`, `locked`),
`per_head_cents`, `has_custom_shares`, `photos` (fields decorated with the assignee's
`color`), `payer_name`; plus top-level `budgets`, `bills` (history summaries),
`settlements`, `total_cents`, `member_count`, `budget_count`, `bill_count`.

### Key domain rules (easy to get wrong)
- **Money is always integer cents.** Client-side math too (see JS). `Splitter.even_split`
  spreads the total evenly, handing out leftover cents one at a time so the shares sum
  *exactly* to the total. `custom_split` **always honours a locked (fixed) share exactly
  as declared — it is never clamped or nudged.** Only the *unlocked* participants absorb
  the remainder (via `even_split` of whatever is left, floored at zero). So the shares sum
  exactly to the total only when the locked shares fit within it: if the locked shares
  already meet or exceed the total, the unlocked participants get `0` and the overshoot is
  left as a gap — and once *every* participant is locked there is no automatic participant
  to absorb anything, so the declared shares stand as-is regardless of the total. That gap
  is surfaced as the meal's `diff_cents` (a red badge next to the payer on the card; see
  `decorate_meal`) for the users to reconcile to zero themselves. Clamping a locked share
  to force the sum was the bug behind both "a fixed share got silently edited" reports —
  don't reintroduce it.
- **Meals split per PERSON, but balances/settlements are per BUDGET.** A budget is one or
  more people pooling money (a couple). Two people sharing a 4-way meal still count as 2
  heads for the split, but owe/are owed as one budget.
- **Budgets are resolved as connected components** (union-find over `budget_id` pointers),
  so grouping is stable regardless of who linked to whom or in what order, and robust to
  chains (A→B→C) and restarts. See `resolve_budgets/1`.
- **Removing a member must scrub every reference** to them (participants, payer, locked
  shares, photo-field assignments, other members' budget pointers) — otherwise the
  snapshot crashes on a dangling id and, because state is persisted, it crash-loops.
  `prune_meal_members/2` does the scrub; it's applied in `remove_member`, in `normalize/1`
  (rehydrate — recovers already-corrupted trips), and defensively in `decorate_meal`.
- **`normalize/1`** runs on every rehydrate and back-fills keys older persisted trips
  predate, dedups OCR fields, and prunes dangling member refs. Always keep it tolerant.

---

## LiveView ⇄ JS hooks — the important gotchas

The client is a set of LiveView **Hooks** under `assets/js/hooks/` (wired together in
`assets/js/app.js`, with shared state in `assets/js/lib/`). Because the server owns
state, the golden rule is:

> **morphdom reconciles each element's attributes back to the server-rendered HTML on
> every re-render.** Anything a hook sets on an element (inline `style`, a client-added
> child, a class) is **stripped** unless the server also renders it.

Consequences (all learned the hard way — don't reintroduce these bugs):
- Client-set **inline styles** (z-index, transforms, positions) are lost on re-render.
  Fix by either (a) re-applying in the hook's `updated()` from a JS-side store, or
  (b) putting client-managed DOM inside a **`phx-update="ignore"`** element (which needs
  an `id`). Examples in the code:
  - `MealCard.updated()` re-applies stacking z-index from `mealZOrder`.
  - Field connector `<svg>` and the photo "processing" placeholder live in
    `phx-update="ignore"` slots.
  - The pan/zoom transform is stored as **CSS custom properties on `:root`**
    (`--siano-pan-x/-y`, `--siano-scale`) via `BoardView`, so re-renders never touch it.
- **Every `phx-hook` element needs a stable `id`** or `mix compile` fails.
- Native `confirm()`/`prompt()`/`alert()` **drop the app out of full-screen** → never use
  them. Use the in-page confirm modal (`Confirm` hook + `window.sianoConfirm(msg, onYes)`)
  and `contentEditable`/inputs for editing.
- Drawer open/closed state is **server-tracked** (`@drawer` assign), not client classes,
  so re-renders don't snap drawers shut.
- Client-only preferences are in **localStorage**: `siano:trips` (followed trips),
  `siano:me:<tripId>` (personal-ledger identity).

### Hook catalogue (`assets/js/hooks/`, one file per concern)
`PanZoom` (`pan_zoom.js` — board pan/zoom, rotation re-centre), `Traveller`
(`traveller.js` — tap-select vs drag; drag ghost), `MealCard` (`meal_card.js` — move card,
z-order, field-tap → total-if-amount-armed / else assign), `FieldLabel` (`field_label.js`
— draggable OCR label: tap=total-if-amount-armed/else-assign-if-armed/else-edit, drag=move,
draws connector), `AmountField` (`misc.js` — tracks focus of a meal's Total input so a
field tap can fill the total), `BillPhoto` / `PhotoUpload` /
`TopPhoto` (`photos.js` — camera uploads via shared `uploadBillPhoto`; long-press to
add/re-scan a field), `Gestures` (`gestures.js` — edge-swipe drawers), `DrawerWatch`
(`drawers.js` — Android back button closes drawers), `Confirm` + `QR` (`dialogs.js` —
in-page modal + trip QR), `Ledger` + `TripSwitcher` (`trips.js` — personal ledger identity;
followed-trips list + New trip), `NetSpeed` (`net_speed.js`), `LocalTime` / `Focus` /
`LongPress` (`misc.js` — local time; autofocus; hold a name to edit share).

Shared modules in `assets/js/lib/` (imported by the hooks): `board.js` → `BoardView`
(pan/zoom state + `toCanvas`/`zoomAt`), `zorder.js` → `mealZOrder`/`bringToFront`/`applyZ`
(z-index per meal), `selection.js` → `selectedMember`/`setSelectedTraveller` (armed
traveller), `amount.js` → `armedAmount`/`amountArmedFor`/`endAmountArm` (which meal's Total
input is focused, so a bill-field tap fills the total), `net.js` → `NetMeter` (+ installs
the WebSocket/fetch byte counter on import).
Cross-cutting window globals: `window.__sianoDragging` / `window.__sianoPanning` (gesture
flags so edge-swipes/pans don't fight drags), `window.sianoConfirm`.

---

## OCR pipeline (`Siano.Ocr` + `PhotoController`)

1. Client resizes the photo, **generates the photo id** itself, and uploads it
   **once** to `POST /t/:id/photos` (id sent as `photo_id`).
   (It used to upload up to four rotated copies to `/t/:id/ocr_score` to find
   the upright angle; that round-trip is gone — orientation is now server-side.)
2. `PhotoController.create` **auto-straightens** the bill server-side
   (`Siano.Images.orient_upright` — tries 0/90/180/270° via ImageMagick, keeps
   whichever OCR-scores best), saves the upright bytes (`Photos.save_bytes`)
   under the client-supplied id (`resolve_photo_id`, sanitised; falls back to a
   server id), attaches a photo record (`add_photo`), OCRs in a background `Task`
   (`Ocr.recognize/2` → `set_photo_fields`), and returns the chosen `angle`.
   Straightening runs inline so the stored image is upright on first render; if
   ImageMagick is missing on the host it degrades gracefully to storing as-is.
   - **Uploader-only local preview:** the uploading device already holds the
     bytes, so `hooks/photos.js` (`localPhotos` + `BillPhoto`) shows its own
     copy — rotated by the returned `angle` — instead of downloading the stored
     image back. It keys on the client-generated id so the mapping exists before
     the broadcast `<img>` mounts. Other viewers (and this device after a reload)
     have no local copy and fall back to the server URL. Overlays still line up
     because field coords are fractional (0..1) and the orientation matches.
3. `Ocr` asks Tika for **hOCR** (per-word bounding boxes), runs **multiple
   page-segmentation passes** and merges/de-dups price-like tokens. Boxes are normalised
   to 0..1 of the image.
4. **Long-press an empty spot** on the photo → client crops a zoomed region, `POST
   /t/:id/photos/:photo_id/ocr_region`, server re-OCRs the crop and maps coords back
   (`add_fields`). **Long-press an existing field** → same, but `replace` index →
   `rescan_field` improves that field (keeps its assignment).
5. **Tapping a field/label** does one of three things, in priority order:
   - if the meal's **Total input is focused** for writing, the field's value is written to
     the meal total (`set_amount_from_field`) — a photo-driven way to fill the total in.
     Focus is tracked client-side (`lib/amount.js` + the `AmountField` hook); the tap
     consumes it (one-shot). The server always re-broadcasts so the optimistically-cleared
     input re-syncs (LiveView won't overwrite a *focused* input's value);
   - else if a **traveller is armed**, it assigns the field to them (`assign_field`); the
     traveller's custom share becomes the sum of their fields;
   - else tapping a label opens an inline editor (`correct_field`).

Requires the Tika **`-full`** image (bundles Tesseract + ImageMagick). Tunables are all
env vars (see below). Header casing matters: `X-Tika-OCROutputType`, `X-Tika-OCRLanguage`,
`X-Tika-OCRPageSegMode`, `X-Tika-OCRenableImagePreprocessing`, etc.

---

## Environment variables

| Var | Default | Purpose |
|---|---|---|
| `SIANO_DATA_DIR` | `siano_data` | Where `:dets` file + bill photos live. |
| `TIKA_URL` | `http://localhost:9998` | Apache Tika OCR server. |
| `SIANO_OCR_LANG` | `eng` | Tesseract language(s), e.g. `pol+eng`. |
| `SIANO_OCR_PSMS` / `SIANO_OCR_REGION_PSMS` | `4,6,11` / `6,11,7` | Page-seg passes. |
| `SIANO_OCR_PREPROCESS` | `true` | Enable ImageMagick preprocessing (upscale/density). |
| `SIANO_OCR_RESIZE` / `SIANO_OCR_DENSITY` / `SIANO_OCR_DEPTH` | `300` / `300` / `8` | Preprocessing knobs. |
| `SIANO_IMAGEMAGICK` | auto (`magick`, else `convert`) | ImageMagick binary used to straighten bill photos server-side. Must be on the **app host** (not just the Tika container); if absent, photos are stored un-rotated. |
| `PHX_HOST` / `PORT` / `SECRET_KEY_BASE` / `PHX_SERVER` | — | Prod runtime (see `config/runtime.exs`). |

---

## Recipes: how to add things

**A new server-side action / mutation** (e.g. a new meal operation):
1. Add `def foo(id, ...) , do: call(id, {:foo, ...})` to `TripServer` (client API section).
2. Add `def handle_call({:foo, ...}, _from, state)` — mutate `state`, then
   `reply_and_broadcast(state)`. Use `update_meal/3` for per-meal edits.
3. Add `defdelegate foo(...), to: TripServer` in `lib/siano/trips.ex`.
4. Add a `handle_event("foo", params, socket)` in `trip_live.ex` calling `Trips.foo(...)`.
5. Add the trigger in the template (a `phx-click`/`phx-blur`, or push from a JS hook).
6. If the change adds new derived data, extend `Snapshot.build_snapshot`/`decorate_meal`.

**A new bit of client behaviour**: add `export const X = {...}` in a new (or existing)
`assets/js/hooks/*.js`, then `import { X }` it into `app.js` and add it to the `Hooks`
map. Put `phx-hook="X"` (+ an `id`) on the element. Remember the morphdom rule: persist anything
you set on the element yourself (store it in JS and re-apply in `updated()`, or use a
`phx-update="ignore"` slot). Push events with `this.pushEvent("evt", payload[, reply])`.

**Styling**: prefer Tailwind utility classes in the template. Custom CSS goes in
`app.css` **after** the `@tailwind` directives (so it wins at equal specificity).
`landscape:`/`portrait:` variants are available (Tailwind 3.4). For JS-generated markup,
use inline styles or classes that also appear in a `.heex`/`.js` file (Tailwind only
generates classes it can see in the content globs).

---

## Conventions & house style

- Match the surrounding code's density and comment style. Existing modules have thoughtful
  `@moduledoc`/comments explaining *why*; keep that up — many comments encode a bug that
  was fixed, so don't strip them.
- Money in **integer cents** everywhere, client and server.
- Keep `Splitter`/`Money`/`Ocr` **pure and Phoenix-free** so they stay unit-testable in a
  standalone `.exs`.
- Server owns truth; the client is a view + gestures. Don't duplicate business logic in JS
  beyond the integer-cent display math already there.
- **Mobile-first.** The app is used on a phone, often full-screen/PWA. Test both portrait
  and landscape. Avoid anything that exits full-screen (native dialogs).
- Chrome autofill: money/name inputs use `type="search"` + `inputmode` + `autocomplete=off`
  to suppress the password/credit-card bar while keeping the right keyboard.
- Don't add dependencies casually — a core selling point is that this runs with no DB and
  minimal deps.

---

## Quick file-finding index

- "How is a bill split / who owes whom?" → `splitter.ex`, `snapshot.ex` (`build_snapshot`, `resolve_budgets`).
- "Where does a drag do its thing?" → `hooks/traveller.js` / `hooks/meal_card.js`,
  `drop_on_meal` / `drop_on_board` / `move_meal` in `trip_live.ex`.
- "OCR / photo fields" → `ocr.ex`, `photo_controller.ex`, `hooks/photos.js` (BillPhoto) /
  `hooks/field_label.js`, `assign_field`/`correct_field`/`rescan_field`/`add_fields` in `trip_server.ex`.
- "Persistence / restarts" → `store.ex`, `normalize/1`, `application.ex`.
- "Layout / responsive / drawers" → `trip_live.html.heex`, `app.css`, `Hooks.Gestures`/`DrawerWatch`.
