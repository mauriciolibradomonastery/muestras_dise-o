const CACHE = 'auditorias-v4';
const BASICOS = [
    './',
    './index.html',
    './agenda.html',
    './auditoria.html',
    './reportes.html',
    './manifest.json',
    './icono-192.png'
];

self.addEventListener('install', e => {
    e.waitUntil(
        caches.open(CACHE).then(c => c.addAll(BASICOS)).catch(() => {})
    );
    self.skipWaiting();
});

self.addEventListener('activate', e => {
    e.waitUntil(
        caches.keys().then(nombres =>
            Promise.all(nombres.filter(n => n !== CACHE).map(n => caches.delete(n)))
        )
    );
    self.clients.claim();
});

self.addEventListener('fetch', e => {
    if (e.request.method !== 'GET') return;
    e.respondWith(
        fetch(e.request)
            .then(res => {
                const copia = res.clone();
                caches.open(CACHE).then(c => c.put(e.request, copia));
                return res;
            })
            .catch(() => caches.match(e.request))
    );
});