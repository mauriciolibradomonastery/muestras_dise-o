// Service worker mínimo: permite instalar la aplicación y guarda en caché
// solo lo estático. Los datos siempre se piden a internet, nunca a la caché.
const CACHE = 'auditorias-v2';
const BASICOS = ['index.html', 'agenda.html', 'auditoria.html', 'manifest.json', 'logo.png', 'icono-192.png', 'icono-512.png'];

self.addEventListener('install', e => {
    e.waitUntil(caches.open(CACHE).then(c => c.addAll(BASICOS).catch(() => {})));
    self.skipWaiting();
});

self.addEventListener('activate', e => {
    e.waitUntil(caches.keys().then(nombres =>
        Promise.all(nombres.filter(n => n !== CACHE).map(n => caches.delete(n)))));
    self.clients.claim();
});

self.addEventListener('fetch', e => {
    const url = new URL(e.request.url);
    // Nunca guardar en caché las llamadas a Supabase ni nada que no sea de esta carpeta
    if (e.request.method !== 'GET' || url.origin !== location.origin) return;

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
