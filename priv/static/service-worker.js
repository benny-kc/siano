// Minimal service worker — its main job is to make Siano an installable PWA
// (Chrome requires a service worker with a fetch handler) and to keep the app
// shell / icons available offline. It is deliberately network-first so it
// never serves a stale LiveView page, and it stays completely out of the way
// of the realtime LiveView socket.

const CACHE = "siano-v1";
const PRECACHE = [
  "/images/icon-192.png",
  "/images/icon-512.png",
  "/images/apple-touch-icon.png",
  "/manifest.webmanifest"
];

self.addEventListener("install", (event) => {
  self.skipWaiting();
  event.waitUntil(
    caches.open(CACHE).then((cache) => cache.addAll(PRECACHE)).catch(() => {})
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const req = event.request;

  // Only handle top-level GETs. Never intercept the LiveView websocket /
  // long-poll or live-reload traffic.
  if (
    req.method !== "GET" ||
    req.url.includes("/live") ||
    req.url.includes("/phoenix")
  ) {
    return;
  }

  // Network-first: always try the live server, fall back to the cache only
  // when offline (so the icons and app shell still resolve).
  event.respondWith(fetch(req).catch(() => caches.match(req)));
});
