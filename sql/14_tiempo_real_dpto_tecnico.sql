-- =====================================================================
-- 14 · TIEMPO REAL PARA dpto_tecnico  ·  Monastery · Dpto. Técnico
-- ---------------------------------------------------------------------
-- QUÉ HACE
--   Agrega la tabla dpto_tecnico a la publicación "supabase_realtime". Así, cuando
--   alguien guarda, importa o borra una muestra, Supabase avisa al instante a las
--   demás pantallas de patronaje abiertas (botón de refresco automático, paso 1.2).
--
-- POR QUÉ
--   Al 2026-11-25 la publicación supabase_realtime no tenía NINGUNA tabla: las
--   pantallas abiertas desde temprano no veían lo que otros guardaban.
--   (Ojo: por la misma razón el refresco automático de Diseño —prendas— tampoco
--    funciona; queda como pendiente aparte, no se toca aquí.)
--
-- SEGURIDAD
--   Realtime respeta RLS: solo usuarios con sesión (rol authenticated) reciben los
--   cambios, igual que hoy pueden leer la tabla. No cambia ningún permiso.
--
-- Idempotente. Ejecutar completo en Supabase → SQL Editor.
-- =====================================================================

do $$
begin
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'dpto_tecnico') then
        alter publication supabase_realtime add table public.dpto_tecnico;
    end if;
end $$;

-- Verificación (solo lectura): debe aparecer public.dpto_tecnico
select schemaname || '.' || tablename as tabla_en_tiempo_real
  from pg_publication_tables where pubname = 'supabase_realtime';

-- VOLVER ATRÁS
--   alter publication supabase_realtime drop table public.dpto_tecnico;
