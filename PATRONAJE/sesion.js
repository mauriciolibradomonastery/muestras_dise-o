// =====================================================================
// GUARDIÁN DE SESIÓN  ·  Monastery
// ---------------------------------------------------------------------
// Cierra la sesión sola cuando:
//   1. Cambia el día (al llegar al otro día hay que volver a entrar), y
//   2. Pasan más de X horas sin actividad.
//
// Cómo usarlo: agrega esta línea en el <head> de cada página protegida
//     <script type="module" src="sesion.js"></script>
// Si la página pertenece a otro login (por ejemplo patronaje), se indica así:
//     <script type="module" src="sesion.js" data-login="index_patronaje.html"></script>
// =====================================================================

import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';

const SUPABASE_URL = 'https://emljzsxypeqecevffmwr.supabase.co';
const SUPABASE_KEY = 'sb_publishable_Y4Cv4QiSPSio1hO4eWvl4A_iTigJS0W';

const HORAS_INACTIVIDAD = 4;      // ← tiempo sin usar la página antes de cerrar

// A qué login se devuelve: por defecto index.html, salvo que la etiqueta diga otra cosa
const etiqueta = document.querySelector('script[src*="sesion.js"]');
const PAGINA_LOGIN = (etiqueta && etiqueta.dataset.login) || 'index.html';

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY, { auth: { storage: window.localStorage } });

const hoy = () => new Date().toLocaleDateString('sv');      // formato 2026-09-23
const LLAVE_DIA = 'sesion_dia';
const LLAVE_ACTIVIDAD = 'sesion_actividad';

async function cerrarYSalir(motivo) {
    localStorage.setItem('sesion_motivo', motivo);
    localStorage.removeItem(LLAVE_DIA);
    localStorage.removeItem(LLAVE_ACTIVIDAD);
    try { await supabase.auth.signOut(); } catch (e) { /* igual se sale */ }
    location.replace(PAGINA_LOGIN);
}

function marcarActividad() {
    localStorage.setItem(LLAVE_ACTIVIDAD, Date.now().toString());
    localStorage.setItem(LLAVE_DIA, hoy());
}

export async function vigilarSesion() {
    const { data: { session } } = await supabase.auth.getSession();
    if (!session) { location.replace(PAGINA_LOGIN); return; }

    const dia = localStorage.getItem(LLAVE_DIA);
    const ultima = Number(localStorage.getItem(LLAVE_ACTIVIDAD) || 0);
    const horasQuieto = (Date.now() - ultima) / 3600000;

    if (dia && dia !== hoy())                          return cerrarYSalir('dia');
    if (ultima && horasQuieto > HORAS_INACTIVIDAD)     return cerrarYSalir('inactividad');

    marcarActividad();

    // Se anota la actividad mientras la persona usa la página
    let ultimoRegistro = Date.now();
    ['click', 'keydown', 'scroll'].forEach(evento =>
        document.addEventListener(evento, () => {
            if (Date.now() - ultimoRegistro > 60000) { marcarActividad(); ultimoRegistro = Date.now(); }
        }, { passive: true }));

    // Revisión cada minuto, por si la pestaña queda abierta toda la noche
    setInterval(() => {
        const guardado = localStorage.getItem(LLAVE_DIA);
        const inactivo = (Date.now() - Number(localStorage.getItem(LLAVE_ACTIVIDAD) || 0)) / 3600000;
        if (guardado && guardado !== hoy()) cerrarYSalir('dia');
        else if (inactivo > HORAS_INACTIVIDAD) cerrarYSalir('inactividad');
    }, 60000);
}

vigilarSesion();
