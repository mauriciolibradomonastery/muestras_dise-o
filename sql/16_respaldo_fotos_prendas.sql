-- =====================================================================
-- 16 · RESPALDO DE LAS FOTOS EN BASE64 DEL INVENTARIO (antes del paso 3.1b)  ·  Monastery
-- ---------------------------------------------------------------------
-- QUÉ HACE
--   Copia a respaldo.fotos_prendas_20261125 el id, el precinto y la foto (base64) de
--   cada prenda que todavía tiene la foto dentro de la tabla. Es el seguro antes de
--   correr migrar_fotos_inventario.html, que sube esas fotos a Storage y deja en
--   prendas.fotoUrl solo el enlace.
--
-- Solo lectura sobre prendas: NO cambia ningún dato del inventario.
-- Idempotente: si el respaldo ya existe no se sobrescribe.
-- Ejecutar completo en Supabase → SQL Editor ANTES de abrir la página de migración.
-- =====================================================================

begin;

create table if not exists respaldo.fotos_prendas_20261125 as
    select id, precinto, "fotoUrl", now() as respaldado_en
      from public.prendas
     where "fotoUrl" like 'data:%';

commit;

-- Verificación (solo lectura): deben coincidir las dos cifras (345 al 2026-11-25)
select (select count(*) from respaldo.fotos_prendas_20261125)                 as fotos_respaldadas,
       (select count(*) from public.prendas where "fotoUrl" like 'data:%')    as fotos_base64_hoy,
       (select pg_size_pretty(sum(length("fotoUrl"))) from respaldo.fotos_prendas_20261125) as tamano;

-- =====================================================================
-- VOLVER ATRÁS (solo si la migración saliera mal): devuelve la foto base64 a cada
-- prenda que tenga ahora un enlace de inventario-fotos.
--   update public.prendas p
--      set "fotoUrl" = r."fotoUrl"
--     from respaldo.fotos_prendas_20261125 r
--    where r.id = p.id
--      and p."fotoUrl" like '%/inventario-fotos/%';
-- =====================================================================
