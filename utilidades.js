// =====================================================================
// UTILIDADES COMPARTIDAS  ·  Monastery
// ---------------------------------------------------------------------
// Cargar como script clásico ANTES del script principal de la página:
//     <script src="utilidades.js"></script>
//
// Contiene:
//   1. crearLogger           → mensajes de consola con nivel, hora y módulo
//   2. crearRecargaAgrupada  → evita descargas repetidas de una tabla cuando
//                              llegan muchos eventos de Realtime seguidos
//                              (por ejemplo, al importar una plantilla de Excel)
// =====================================================================

/**
 * Logger con niveles, marca de tiempo y módulo.
 * Centraliza los mensajes para poder filtrarlos o redirigirlos
 * sin tocar el resto del código.
 *
 * @param {string} modulo  Ejemplo: 'dashboard/prendas'
 */
function crearLogger(modulo) {
    /**
     * @param {string} nivel
     * @param {string} mensaje
     * @param {unknown} [extra]
     */
    const formatear = (nivel, mensaje, extra) =>
        [`[${new Date().toISOString()}] [${nivel}] [${modulo}] ${mensaje}`, extra ?? ''];

    return {
        /** @param {string} mensaje @param {unknown} [extra] */
        info: (mensaje, extra) => console.info(...formatear('INFO', mensaje, extra)),
        /** @param {string} mensaje @param {unknown} [extra] */
        warn: (mensaje, extra) => console.warn(...formatear('WARN', mensaje, extra)),
        /** @param {string} mensaje @param {unknown} [extra] */
        error: (mensaje, extra) => console.error(...formatear('ERROR', mensaje, extra)),
    };
}

/**
 * Envuelve una función de carga para que:
 *  - una ráfaga de solicitudes produzca UNA sola ejecución (debounce),
 *  - la espera nunca supere `esperaMaximaMs` aunque las solicitudes no paren,
 *  - nunca corran dos cargas al mismo tiempo (single-flight),
 *  - si llegan solicitudes durante una carga, se haga una recarga final.
 *
 * @param {() => Promise<void>} cargar  Función que descarga y pinta los datos.
 * @param {{ esperaMs?: number, esperaMaximaMs?: number, log: ReturnType<typeof crearLogger> }} opciones
 * @returns {(motivo?: string, config?: { inmediato?: boolean }) => void}
 */
function crearRecargaAgrupada(cargar, { esperaMs = 1500, esperaMaximaMs = 10000, log }) {
    if (typeof cargar !== 'function') {
        throw new TypeError('crearRecargaAgrupada: "cargar" debe ser una función');
    }

    /** @type {ReturnType<typeof setTimeout> | null} */
    let temporizador = null;
    /** @type {number | null} */
    let primeraSolicitud = null;
    let enCurso = false;
    let pendiente = false;
    let solicitudesAgrupadas = 0;

    async function ejecutar() {
        temporizador = null;
        primeraSolicitud = null;

        // Si ya hay una carga corriendo, no se lanza otra en paralelo:
        // se marca como pendiente y se repite al terminar la actual.
        if (enCurso) { pendiente = true; return; }

        enCurso = true;
        const agrupadas = solicitudesAgrupadas;
        solicitudesAgrupadas = 0;
        const inicio = performance.now();

        try {
            await cargar();
            log.info(`Recarga completada (${agrupadas} solicitud(es) agrupadas)`,
                     { ms: Math.round(performance.now() - inicio) });
        } catch (err) {
            log.error('Falló la recarga', err);
        } finally {
            enCurso = false;
            if (pendiente) {
                pendiente = false;
                solicitar('cambios recibidos durante la carga');
            }
        }
    }

    /**
     * @param {string} [motivo]  Texto para el log (ej.: 'evento Realtime').
     * @param {{ inmediato?: boolean }} [config]  inmediato: true para no esperar (carga inicial).
     */
    function solicitar(motivo = 'sin especificar', { inmediato = false } = {}) {
        solicitudesAgrupadas++;
        const ahora = Date.now();

        if (primeraSolicitud === null) {
            primeraSolicitud = ahora;
            log.info(`Recarga solicitada: ${motivo}`);
        }
        if (temporizador !== null) clearTimeout(temporizador);

        if (inmediato) { ejecutar(); return; }

        const restante = Math.max(0, esperaMaximaMs - (ahora - primeraSolicitud));
        temporizador = setTimeout(ejecutar, Math.min(esperaMs, restante));
    }

    return solicitar;
}

// =====================================================================
// FOTOS DEL INVENTARIO (paso 3.1a, 2026-11-25)
// ---------------------------------------------------------------------
// Antes, formulario.html, dashboard.html y salidas.html tenían cada uno su copia del
// mismo código: comprimían la foto y la guardaban en base64 DENTRO de prendas.fotoUrl.
// Eso hacía que cada carga del inventario descargara todas las fotos (~9 MB).
// Ahora las tres usan esta función: comprime igual que antes (máx. 600 px, JPEG al 60 %),
// la sube al bucket "inventario-fotos" (sql/15) y devuelve SOLO el enlace.
// Si algo falla LANZA un error: nunca guarda la foto en base64 como "plan B".
// =====================================================================
const BUCKET_FOTOS_INVENTARIO = 'inventario-fotos';

/**
 * Reduce una imagen a máx. `lado` px por lado y la convierte a JPEG.
 * @param {File|Blob} archivo
 * @param {number} [lado=600]
 * @param {number} [calidad=0.6]
 * @returns {Promise<Blob>}
 */
function comprimirImagen(archivo, lado = 600, calidad = 0.6) {
    return new Promise((resolve, reject) => {
        const url = URL.createObjectURL(archivo);
        const img = new Image();
        img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('El archivo no es una imagen que el navegador pueda abrir (usa JPG o PNG).')); };
        img.onload = () => {
            URL.revokeObjectURL(url);
            let { width, height } = img;
            if (width > height) { if (width > lado) { height *= lado / width; width = lado; } }
            else if (height > lado) { width *= lado / height; height = lado; }
            const canvas = document.createElement('canvas');
            canvas.width = Math.round(width); canvas.height = Math.round(height);
            canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
            canvas.toBlob(blob => blob ? resolve(blob) : reject(new Error('No se pudo comprimir la imagen.')), 'image/jpeg', calidad);
        };
        img.src = url;
    });
}

/**
 * Comprime y sube la foto de una muestra. Devuelve la URL pública para guardar en prendas.fotoUrl.
 * @param {object} cliente   Cliente de Supabase de la página.
 * @param {File} archivo     Archivo elegido por el usuario.
 * @param {string} [precinto] Para nombrar el archivo (facilita encontrarlo en Storage).
 * @returns {Promise<string>}
 */
async function subirFotoInventario(cliente, archivo, precinto) {
    if (!cliente || !cliente.storage) throw new Error('subirFotoInventario: falta el cliente de Supabase.');
    if (!archivo) throw new Error('subirFotoInventario: no se recibió ningún archivo.');
    const blob = await comprimirImagen(archivo);
    const base = String(precinto || 'sin-precinto').trim().toUpperCase().replace(/[^A-Z0-9_-]/g, '_') || 'sin-precinto';
    const nombre = `${base}_${Date.now()}_${Math.random().toString(36).slice(2, 8)}.jpg`;
    const { error } = await cliente.storage.from(BUCKET_FOTOS_INVENTARIO)
        .upload(nombre, blob, { contentType: 'image/jpeg', upsert: false, cacheControl: '31536000' });
    if (error) { console.error('[fotos] No se pudo subir la foto', nombre, error); throw error; }
    const { data } = cliente.storage.from(BUCKET_FOTOS_INVENTARIO).getPublicUrl(nombre);
    if (!data || !data.publicUrl) throw new Error('La foto se subió pero no se obtuvo su enlace.');
    return data.publicUrl;
}
