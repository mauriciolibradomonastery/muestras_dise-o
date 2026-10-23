// =====================================================================
// GUARDIÁN DE SESIÓN  ·  Monastery  (v2)
// ---------------------------------------------------------------------
// Cierra la sesión sola cuando:
//   1. Cambia el día (al llegar al otro día hay que volver a entrar), y
//   2. Pasan más de X horas sin actividad.
//
// Cambios de la v2:
//   · Antes de cerrar, le pide a la página que guarde (window.guardarAntesDeSalir).
//     Si no se puede guardar, NO cierra y lo reintenta al minuto:
//     es mejor una sesión un poco más larga que perder datos.
//   · Un inicio de sesión nuevo ya no se confunde con llaves viejas de otro día
//     (antes, el primer login del día te sacaba de inmediato).
//   · Si la página ya creó su cliente de Supabase (window.sbCliente), lo reutiliza.
//
// Uso (igual que antes), en el <head> de cada página protegida:
//     <script type="module" src="sesion.js"></script>
//     <script type="module" src="sesion.js" data-login="index_patronaje.html"></script>
// =====================================================================

const SUPABASE_URL = 'https://emljzsxypeqecevffmwr.supabase.co';
const SUPABASE_KEY = 'sb_publishable_Y4Cv4QiSPSio1hO4eWvl4A_iTigJS0W';
const URL_LIBRERIA = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';

const HORAS_INACTIVIDAD = 4;      // ← tiempo sin usar la página antes de cerrar
const LOG = '[sesion]';

// A qué login se devuelve: por defecto index.html, salvo que la etiqueta diga otra cosa
const etiqueta = document.querySelector('script[src*="sesion.js"]');
const PAGINA_LOGIN = (etiqueta && etiqueta.dataset.login) || 'index.html';

const LLAVE_DIA = 'sesion_dia';
const LLAVE_ACTIVIDAD = 'sesion_actividad';
const hoy = () => new Date().toLocaleDateString('sv');      // formato 2026-09-23

let supabase = null;
let cerrando = false;

/** Reutiliza el cliente de la página; si no existe, crea uno propio. */
async function obtenerCliente() {
    if (window.sbCliente) return window.sbCliente;
    const { createClient } = await import(URL_LIBRERIA);
    return createClient(SUPABASE_URL, SUPABASE_KEY, { auth: { storage: window.localStorage } });
}

function marcarActividad() {
    localStorage.setItem(LLAVE_ACTIVIDAD, Date.now().toString());
    localStorage.setItem(LLAVE_DIA, hoy());
}

/** Devuelve 'dia', 'inactividad' o null si la sesión puede seguir. */
function motivoDeCierre() {
    const dia = localStorage.getItem(LLAVE_DIA);
    const ultima = Number(localStorage.getItem(LLAVE_ACTIVIDAD) || 0);
    if (dia && dia !== hoy()) return 'dia';
    if (ultima && (Date.now() - ultima) / 3600000 > HORAS_INACTIVIDAD) return 'inactividad';
    return null;
}

/**
 * ¿La persona inició sesión DESPUÉS de su última actividad registrada?
 * Si es así, las llaves guardadas son de una sesión anterior y no deben sacarla.
 */
function esIngresoNuevo(session) {
    const ultima = Number(localStorage.getItem(LLAVE_ACTIVIDAD) || 0);
    const ingreso = Date.parse(session?.user?.last_sign_in_at || '');
    return Number.isFinite(ingreso) && ingreso > ultima;
}

async function cerrarYSalir(motivo) {
    if (cerrando) return;
    cerrando = true;

    // 1) Intentar guardar lo pendiente (solo si la página ofrece esta función)
    try {
        if (typeof window.guardarAntesDeSalir === 'function') {
            await window.guardarAntesDeSalir();
        }
    } catch (e) {
        console.error(`${LOG} No se cerró la sesión (${motivo}) porque quedaron cambios sin guardar. Se reintentará en un minuto.`, e);
        cerrando = false;
        return;
    }

    // 2) Cerrar
    localStorage.setItem('sesion_motivo', motivo);
    localStorage.removeItem(LLAVE_DIA);
    localStorage.removeItem(LLAVE_ACTIVIDAD);
    try {
        await supabase.auth.signOut();
    } catch (e) {
        console.warn(`${LOG} signOut falló; se sale de todas formas.`, e);
    }
    location.replace(PAGINA_LOGIN);
}

export async function vigilarSesion() {
    try {
        supabase = await obtenerCliente();
    } catch (e) {
        console.error(`${LOG} No se pudo cargar la librería de Supabase.`, e);
        return;
    }

    const { data: { session }, error } = await supabase.auth.getSession();
    if (error) console.warn(`${LOG} getSession devolvió un error:`, error);
    if (!session) { location.replace(PAGINA_LOGIN); return; }

    if (esIngresoNuevo(session)) {
        marcarActividad();                       // login reciente: se ignoran llaves viejas
    } else {
        const motivo = motivoDeCierre();
        if (motivo) { await cerrarYSalir(motivo); return; }
        marcarActividad();
    }

    // Se anota la actividad mientras la persona usa la página (máximo una vez por minuto)
    let ultimoRegistro = Date.now();
    ['click', 'keydown', 'scroll', 'touchstart'].forEach(evento =>
        document.addEventListener(evento, () => {
            if (Date.now() - ultimoRegistro > 60000) { marcarActividad(); ultimoRegistro = Date.now(); }
        }, { passive: true }));

    // Revisión cada minuto, por si la pestaña queda abierta toda la noche
    setInterval(() => {
        const motivo = motivoDeCierre();
        if (motivo) cerrarYSalir(motivo);
    }, 60000);
}

vigilarSesion();
