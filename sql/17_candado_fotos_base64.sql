-- =====================================================================
-- 17 · CANDADO CONTRA FOTOS EN BASE64 EN EL INVENTARIO (paso 3.1c)  ·  Monastery
-- ---------------------------------------------------------------------
-- QUÉ HACE
--   Instala el trigger trg_prendas_sin_base64: si alguien intenta guardar en
--   prendas.fotoUrl una imagen incrustada (texto que empieza por "data:"), el
--   guardado se RECHAZA con un mensaje que explica qué hacer.
--
-- POR QUÉ
--   Desde el paso 3.1a las páginas suben la foto a Storage y guardan solo el enlace,
--   y en el 3.1b se migraron las 345 fotos viejas (quedan 0 en base64). Pero una
--   pestaña con la versión VIEJA del formulario en caché (sin Ctrl+Shift+R) o una
--   importación de Excel podrían volver a meter base64 y engordar la tabla.
--   El trigger es la única puerta que cubre todos los caminos (regla 13 del CLAUDE.md).
--
-- POR QUÉ TRIGGER Y NO "CHECK"
--   Una restricción CHECK daría un error técnico ("violates check constraint");
--   el trigger permite un mensaje claro para el usuario.
--
-- No modifica ningún registro: solo vigila lo que entra desde ahora.
-- Idempotente. Ejecutar completo en Supabase → SQL Editor.
-- =====================================================================

begin;

create or replace function public.trg_bloquear_foto_base64()
returns trigger
language plpgsql
set search_path = public
as $$
begin
    if new."fotoUrl" is not null and ltrim(new."fotoUrl") ilike 'data:%' then
        raise exception 'La foto de la muestra % llegó incrustada en el registro (formato viejo) y ya no se acepta. Recarga la página con Ctrl+Shift+R y vuelve a guardar: la foto se subirá al almacenamiento.',
            coalesce(new.precinto, '(sin precinto)')
            using errcode = 'P0001';
    end if;
    return new;
end;
$$;

drop trigger if exists trg_prendas_sin_base64 on public.prendas;
create trigger trg_prendas_sin_base64
    before insert or update of "fotoUrl" on public.prendas
    for each row execute function public.trg_bloquear_foto_base64();

commit;

-- Verificación (solo lectura)
select tgname as trigger, case tgenabled when 'O' then 'activo' else 'INACTIVO' end as estado
  from pg_trigger where tgrelid = 'public.prendas'::regclass and not tgisinternal order by tgname;
select count(*) as fotos_base64_en_prendas from public.prendas where "fotoUrl" like 'data:%';   -- debe ser 0

-- =====================================================================
-- VOLVER ATRÁS
--   drop trigger if exists trg_prendas_sin_base64 on public.prendas;
--
-- OJO: la vuelta atrás de la migración de fotos (sql/16) vuelve a escribir base64.
-- Si alguna vez se necesita, primero:  alter table public.prendas disable trigger trg_prendas_sin_base64;
-- y al terminar:                        alter table public.prendas enable trigger trg_prendas_sin_base64;
-- =====================================================================
