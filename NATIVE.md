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
export SIANO_TWA_PACKAGE="online.siano.twa"          # your Android application id
export SIANO_TWA_FINGERPRINTS="AA:BB:CC:…:FF"         # SHA-256 cert fingerprint(s)
```

> The **application id** (`online.siano.twa` here — a reverse-DNS of `siano.online`)
> is a permanent identity for the app on a device and in the Play Store: pick it
> once and keep it. Change it freely *before* the first install/publish; changing
> it later makes a separate app. Any valid value works — `pl.atende.siano` is
> equally fine — as long as it matches what you set when building the APK below.

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
curl -s https://siano.online/.well-known/assetlinks.json | jq .
```

Expected shape:

```json
[
  {
    "relation": ["delegate_permission/common.handle_all_urls"],
    "target": {
      "namespace": "android_app",
      "package_name": "online.siano.twa",
      "sha256_cert_fingerprints": ["AA:BB:CC:…:FF"]
    }
  }
]
```

Google's [Statement List Generator & Tester](https://developers.google.com/digital-asset-links/tools/generator)
can double-check it against your package + fingerprint.

### 4. Build the app file

The wrapper is a thin shell that loads `https://siano.online` — **it does not
bundle the Elixir backend**, so the phone must be able to reach that host over
HTTPS. Two output formats matter:

- **APK** — the file you can sideload: copy to a phone and tap, or `adb install`.
- **AAB** (Android App Bundle) — upload-only, for the Play Store; you can't
  install it directly.

Two easy generators — pick one:

- **[PWABuilder](https://www.pwabuilder.com/)** (GUI, no local Android toolchain)
  — enter `https://siano.online`, **Package for stores → Android**, set the
  Package ID to `online.siano.twa`, **Download**. You get a signed `.apk`, an
  `.aab`, the signing `.keystore` (+ passwords), and the exact `assetlinks.json`.
- **[Bubblewrap](https://github.com/GoogleChromeLabs/bubblewrap)** (CLI):

  ```sh
  npm i -g @bubblewrap/cli
  bubblewrap init --manifest https://siano.online/manifest.webmanifest
  #   → set the Application ID to online.siano.twa when prompted
  #   → it offers to download the JDK + Android SDK for you
  bubblewrap build      # → app-release-signed.apk (+ .aab) and the signing fingerprint
  ```

Either way, **keep the signing keystore + passwords safe** — the same key is
required to ship every future update.

### 5. Generate a sideloadable APK (skip the Play Store)

To install on any device yourself (no Play Store):

1. Build the **APK** as in step 4 (`app-release-signed.apk`).
2. Grab its signing fingerprint and finish the asset-links wiring so it opens
   chrome-free:

   ```sh
   bubblewrap fingerprint
   # or, from a keystore:
   keytool -list -v -keystore android.keystore -alias android | grep SHA256
   ```

   Put that SHA-256 in `SIANO_TWA_FINGERPRINTS` on the server (step 1), restart,
   and re-check `https://siano.online/.well-known/assetlinks.json` (step 3).
3. Install it:

   ```sh
   adb install app-release-signed.apk        # over USB (USB debugging on)
   ```

   …or copy the `.apk` to the phone and tap it, allowing **“Install unknown
   apps”** for your file manager / browser when prompted.

If verification succeeds the app opens **full-screen with no browser bar**. A
thin address bar means the asset-links check failed — re-check that the package
name and fingerprint match exactly between the APK and `assetlinks.json`. The
device also needs **Chrome (or another TWA-capable browser)** installed, since
the TWA uses it as the rendering engine.

### 6. Publish to the Play Store (optional)

Upload the `.aab` (not the APK) to the Play Console. TWAs are explicitly
supported, so there's no "just a website" friction. Once you enroll in **Play
App Signing**, add the Play-managed key's SHA-256 to `SIANO_TWA_FINGERPRINTS`
too (Play re-signs your app, so that key is what installed devices actually see).

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
    url: 'https://siano.online',
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
