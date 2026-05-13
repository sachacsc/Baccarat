// Service worker minimaliste pour rendre l'app installable + un peu de cache.
//
// Stratégie : network-first sur l'HTML (pour toujours avoir la dernière version après deploy),
// cache-first sur les assets statiques (icônes, images). Pas de pre-cache lourd : on évite que
// le SW serve une vieille version du build après push (le piège classique des PWA mal réglées).
//
// Le SW se met à jour automatiquement à chaque navigation : on incrémente CACHE_VERSION quand
// on push une nouvelle version qui doit invalider le cache (ex: nouvelles icônes, nouveaux assets).

const CACHE_VERSION = 'v3-ios-card-fix';
const CACHE_NAME = `baccarat-${CACHE_VERSION}`;
const STATIC_ASSETS = [
  './',
  './manifest.json',
  './icon-192.png',
  './icon-512.png',
  './apple-touch-icon.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(STATIC_ASSETS)).catch(() => {})
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);
  // On ne touche pas aux requêtes vers d'autres origines (Supabase, CDN, PeerJS, Metered TURN, etc.)
  if (url.origin !== self.location.origin) return;

  // HTML : network-first (toujours la dernière version), fallback cache si offline
  if (req.mode === 'navigate' || req.destination === 'document') {
    event.respondWith(
      fetch(req).then((resp) => {
        const copy = resp.clone();
        caches.open(CACHE_NAME).then((c) => c.put(req, copy));
        return resp;
      }).catch(() => caches.match(req).then((c) => c || caches.match('./')))
    );
    return;
  }

  // Assets statiques : cache-first
  event.respondWith(
    caches.match(req).then((cached) => {
      if (cached) return cached;
      return fetch(req).then((resp) => {
        const copy = resp.clone();
        caches.open(CACHE_NAME).then((c) => c.put(req, copy));
        return resp;
      });
    })
  );
});
