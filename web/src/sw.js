// Caches the whole app so it keeps working with no connection.
const CACHE = 'hbr-v3';
const FILES = ['./', 'index.html', 'app.js', 'hbr_core.js', 'hbr_core.wasm', 'manifest.webmanifest',
  'vendor/vision_wasm_internal.js', 'vendor/vision_wasm_internal.wasm',
  'models.js'];
self.addEventListener('install', (e) => e.waitUntil(caches.open(CACHE).then((c) => c.addAll(FILES)).then(() => self.skipWaiting())));
self.addEventListener('activate', (e) => e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim())));
self.addEventListener('fetch', (e) => {
  if (e.request.method !== 'GET') return;
  e.respondWith(caches.match(e.request, { ignoreSearch: true }).then((r) => r || fetch(e.request)));
});
