# Shipping Siano as a native app

Siano is a real-time **Phoenix LiveView** app: the server owns all state and the
board/drag-drop/OCR UI lives in the browser as LiveView + JS hooks. The lowest-
effort, highest-fidelity way to get it into the App Store / Play Store is **not**
to rewrite the UI, but to wrap the existing PWA in a thin **native shell** whose
main screen is a full-screen WebView pointed at your hosted Siano URL.

Everything that makes Siano *Siano* — the pannable board, dragging travellers
onto meals, tapping OCR fields — keeps working unchanged inside that WebView.
Nothing in `lib/` (the "engine": `TripServer`, `Splitter`, `Snapshot`, `Report`,
`Ocr`, …) or `assets/` needs to change to ship this way.

> Considering *true* native rendering (SwiftUI / Jetpack Compose) via **LiveView
> Native** instead? That reuses the same Elixir engine but is a full rewrite of
> the UI in one or two native languages, and the game-like board has no drop-in
> native equivalent. For a gesture-driven app like this, the shell below is the
> better effort-to-result trade. Revisit LVN only if you specifically want native
> widgets.

Recommended combo:

| Platform | Approach | Why |
|---|---|---|
| **Android** | **TWA** (Trusted Web Activity) | Google-blessed; runs your PWA chrome-free; near-zero code. |
| **iOS** | **Capacitor** | iOS has no TWA; Capacitor hosts a WebView + gives native camera/plugins. |

Prerequisite for both: Siano must be served over **HTTPS** on a stable domain
(TWA and modern camera APIs require it). The PWA pieces are already in place —
`priv/static/manifest.webmanifest` (`display: "fullscreen"`), the service worker,
and the icons.

---

## Android — Trusted Web Activity (TWA)

A TWA is Chrome rendering your PWA URL full-screen with **no address bar**. It
proves it's allowed to do that (instead of showing a custom-tab bar) via
**Digital Asset Links**: a JSON file served from your domain that names the
Android app and its signing certificate. Siano serves that file for you.

### 1. Serve `assetlinks.json` (already wired)

The route `GET /.well-known/assetlinks.json`
(`lib/siano_web/controllers/well_known_controller.ex`) generates the file from
two env vars. Until both are set it returns **404** — so a plain web deploy is
unaffected.

Set them where you run the app (systemd unit, shell, container env):

```sh
export SIANO_TWA_PACKAGE="pl.atende.siano"          # your Android application id
export SIANO_TWA_FINGERPRINTS="AA:BB:CC:…:FF"        # SHA-256 cert fingerprint(s)
```

`SIANO_TWA_FINGERPRINTS` accepts **several** fingerprints separated by commas or
whitespace. You will usually list **two**:

- your **upload key** fingerprint, and
- the **Google Play app-signing key** fingerprint (from the Play Console once you
  enroll in Play App Signing — Play re-signs your app, so its key is what devices
  actually see).

### 2. Get the fingerprint(s)

From a local keystore:

```sh
keytool -list -v -keystore my-release-key.keystore -alias my-alias \
  | grep "SHA256:"
```

Copy the `SHA256:` value (the `AA:BB:…` hex, colon-separated). For the Play-signed
key, copy it from **Play Console → your app → Setup → App integrity → App signing**.

### 3. Verify the file

After setting the env vars and restarting:

```sh
curl -s https://YOUR_HOST/.well-known/assetlinks.json | jq .
```

Expected shape:

```json
[
  {
    "relation": ["delegate_permission/common.handle_all_urls"],
    "target": {
      "namespace": "android_app",
      "package_name": "pl.atende.siano",
      "sha256_cert_fingerprints": ["AA:BB:CC:…:FF"]
    }
  }
]
```

Google's [Statement List Generator & Tester](https://developers.google.com/digital-asset-links/tools/generator)
can double-check it against your package + fingerprint.

### 4. Build the TWA

Two easy generators — pick one:

- **[PWABuilder](https://www.pwabuilder.com/)** — paste `https://YOUR_HOST`,
  choose the Android package, download the signed project. GUI, fastest start.
- **[Bubblewrap](https://github.com/GoogleChromeLabs/bubblewrap)** (CLI):

  ```sh
  npm i -g @bubblewrap/cli
  bubblewrap init --manifest https://YOUR_HOST/manifest.webmanifest
  # set the application id to match SIANO_TWA_PACKAGE when prompted
  bubblewrap build      # produces an .aab/.apk + prints the signing fingerprint
  ```

  Bubblewrap prints the signing-key SHA-256 — make sure that value is in
  `SIANO_TWA_FINGERPRINTS`.

Install the APK on a device: if verification succeeds the app opens
**full-screen with no browser bar**. A thin address bar means the asset-links
check failed — re-check the package name and fingerprints match exactly.

Then upload the `.aab` to the Play Console. TWAs are explicitly supported, so
there's no "just a website" friction here.

---

## iOS — Capacitor

iOS has no TWA equivalent, so use **[Capacitor](https://capacitorjs.com/)**: a
native shell that hosts a WebView and exposes native plugins.

### 1. Scaffold

Do this in a **separate repo/folder** (it's an Xcode project, not part of the
Elixir app):

```sh
npm init -y
npm i @capacitor/core @capacitor/ios @capacitor/camera
npm i -D @capacitor/cli
npx cap init Siano pl.atende.siano
npx cap add ios
```

### 2. Point the WebView at the live server

Because Siano is a **server-driven LiveView app** (it needs a live WebSocket),
load the hosted URL instead of bundling static assets. In `capacitor.config.ts`:

```ts
import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'pl.atende.siano',
  appName: 'Siano',
  webDir: 'www',                 // a near-empty placeholder; the app loads server.url
  server: {
    url: 'https://YOUR_HOST',
    cleartext: false,
  },
};
export default config;
```

`npx cap sync ios && npx cap open ios`, then run from Xcode.

### 3. Native camera for the OCR flow (already wired)

In the browser, bill photos are captured via `<input type=file>`. The shell picks
up a **native camera** automatically — no code change needed on your side:

- `assets/js/lib/native.js` detects the Capacitor runtime and, **only when the
  Camera plugin is installed**, exposes `hasNativeCamera()` / `captureBillPhoto()`
  by reaching the plugin through the injected `window.Capacitor` globals (so this
  web bundle keeps **no** `@capacitor/camera` build dependency).
- The `PhotoUpload` and `TopPhoto` hooks (`assets/js/hooks/photos.js`) intercept
  the tap in a native shell and capture through the OS camera; otherwise they use
  the normal file `<input>`. Either way the photo flows through the same
  `uploadBillPhoto()` pipeline and `POST /t/:id/photos`, so **no server change is
  needed**.

So all you do on the Capacitor side is install the plugin:

```sh
npm i @capacitor/camera
npx cap sync ios
```

Add the iOS usage strings to `ios/App/App/Info.plist` (required or the app
crashes on first camera use):

```xml
<key>NSCameraUsageDescription</key>
<string>Take a photo of a bill to split it.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>Choose a bill photo to split it.</string>
```

If you *don't* install the plugin, `hasNativeCamera()` is false and the app
silently falls back to the WebView file picker.

### 4. Full-screen manager (already handled)

`assets/js/app.js` has a `fullscreenManager()` that requests browser full-screen
on first tap. A Capacitor app is already chrome-free, so it now short-circuits
via `isNativeShell()` (`assets/js/lib/native.js`) — nothing to change.

---

## Store-submission notes / gotchas

- **Apple guideline 4.2 ("minimum functionality").** Apple sometimes rejects
  apps that are "just a website." Siano is more defensible than most — real-time
  multiplayer state, camera-driven OCR, an interactive board — and leaning on
  native integration (Camera plugin, share sheet, push notifications) strengthens
  the case. Play Store / TWA has no equivalent friction.
- **Connectivity.** The shell is a live WebView, so a dropped network surfaces
  LiveView's reconnect behavior rather than an offline app. Siano already handles
  this (`longPollFallbackMs` in `app.js`, the net meter); consider a clearer
  native offline affordance later.
- **Deep links.** Trip URLs are `/t/:id`. If you want tapping a shared link to
  open the app, configure App Links (Android, reuses the same asset-links file)
  and Universal Links (iOS, needs `apple-app-site-association`).
- **One backend, many clients.** The web app, the Android TWA, and the iOS shell
  all talk to the **same** Phoenix server and the same per-trip GenServer, so a
  trip stays perfectly in sync across a browser and a phone app at once.

---

## Environment variables added for this

| Var | Purpose |
|---|---|
| `SIANO_TWA_PACKAGE` | Android application id for the TWA (e.g. `pl.atende.siano`). |
| `SIANO_TWA_FINGERPRINTS` | SHA-256 signing-cert fingerprint(s), comma/space separated. List both the upload key and the Play app-signing key. |

Both unset ⇒ `/.well-known/assetlinks.json` returns 404 and nothing changes for
the web app.
