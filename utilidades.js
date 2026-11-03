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
