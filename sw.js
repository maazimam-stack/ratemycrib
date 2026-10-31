// RateMyCrib service worker: Add to Home Screen + basic offline use.
// v2 (Oct 2026): the v1 worker served /data/*.json from cache forever, so returning visitors kept an old program
// list. Changing CACHE_NAME makes every browser drop the v1 cache when this worker activates.
const CACHE_NAME = 'rmc-v2';
const PRECACHE = ['/', '/index.html', '/manifest.json'];
// Never stored on the device: admin tools and one-time links (an unsubscribe link carries a private token)
const NEVER_CACHE = /^\/(admin\.html|unsubscribe\.html)$/;

self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE_NAME).then(cache => cache.addAll(PRECACHE)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

function networkFirst(request) {
  return fetch(request).then(response => {
    if (response.ok) {
      const copy = response.clone();
      caches.open(CACHE_NAME).then(cache => cache.put(request, copy));
    }
    return response;
  }).catch(() => caches.match(request));
}

self.addEventListener('fetch', event => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== location.origin) return;           // database and fonts go straight to the network
  if (NEVER_CACHE.test(url.pathname) || url.search) return; // no query-string URLs either (tokens, campaign codes)

  // Pages and data files: always the newest copy, the cached one only when offline
  if (req.mode === 'navigate' || (req.headers.get('accept') || '').includes('text/html') || url.pathname.startsWith('/data/') || url.pathname === '/sw.js') {
    event.respondWith(networkFirst(req));
    return;
  }

  // Versioned files (vendor/*-1.2.3.js) and icons never change in place: cache first
  event.respondWith(
    caches.match(req).then(cached => cached || fetch(req).then(response => {
      if (response.ok) {
        const copy = response.clone();
        caches.open(CACHE_NAME).then(cache => cache.put(req, copy));
      }
      return response;
    }))
  );
});
