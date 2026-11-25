-- =====================================================================
-- 10 · BLOQUEO DE CAMPOS DE DISEÑO EN dpto_tecnico  ·  Monastery
-- ---------------------------------------------------------------------
-- REGLA DE NEGOCIO (decidida 2026-11-25)
--   1. El PRECINTO de una fila existente no se cambia desde la web.
--   2. En filas con precinto MSTMUE..., los campos que vienen del inventario
--      de Diseño no se editan desde la web (se corrigen en Diseño):
--        0 FOTO · 2 DISEÑADOR · 3 GÉNERO · 4 PROVEEDOR · 5 PAÍS · 6 COLECCIÓN
--        7 PRECINTO · 8 REFERENCIA · 9 TALLA · 10 TIPO DE MUESTRA · 11 PINTA
--        12 CANTIDAD · 13 DESCRIPCIÓN
--   3. Las filas manuales (SIN PRECINTO u otro texto) sí se editan, salvo el precinto.
--
-- POR QUÉ TAMBIÉN EN LA BASE (además de la página)
--   La página ya bloquea esas celdas, pero una pestaña con la versión vieja
--   (sin Ctrl+Shift+R) todavía podría enviarlas. El trigger es la última puerta:
--   rechaza el guardado con un mensaje claro y no escribe nada de esa fila.
--
-- QUIÉN QUEDA FUERA DEL BLOQUEO
--   Solo se aplica a peticiones de la web (rol "authenticated"). Un administrador
--   en el SQL Editor (rol postgres) puede corregir datos a mano cuando haga falta.
--   Las inserciones (Importar desde Diseño, Fila Manual) no se bloquean.
--
-- Idempotente. Ejecutar completo en Supabase → SQL Editor.
-- =====================================================================

begin;

create or replace function public.trg_bloquear_campos_diseno()
returns trigger
language plpgsql
set search_path = public
as $$
declare
    v_nombres constant text[] := array[
        'FOTO', 'FECHA DE INGRESO', 'DISEÑADOR', 'GÉNERO', 'PROVEEDOR', 'PAÍS', 'COLECCIÓN',
        'PRECINTO', 'NOMBRE / REFERENCIA', 'TALLA', 'TIPO DE MUESTRA', 'PINTA', 'CANTIDAD',
        'DESCRIPCIÓN PRENDA'];
    v_campos_diseno constant int[] := array[0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13];
    v_de_diseno boolean;
    v_i int;
begin
    -- Solo peticiones de la web; el SQL Editor y procesos internos pasan
    if coalesce(auth.jwt() ->> 'role', '') <> 'authenticated' then
        return new;
    end if;
    if jsonb_typeof(old.datos) <> 'array' or jsonb_typeof(new.datos) <> 'array' then
        return new;
    end if;

    -- 1) El precinto nunca cambia desde la web
    if coalesce(old.datos ->> 7, '') is distinct from coalesce(new.datos ->> 7, '')
       or coalesce(old.precinto, '') is distinct from coalesce(new.precinto, '') then
        raise exception 'No se puede cambiar el PRECINTO de una muestra (%). El precinto solo entra con "Importar desde Diseño". Recarga la página con Ctrl+Shift+R.',
            coalesce(old.precinto, '(vacío)')
            using errcode = 'P0001';
    end if;

    -- 2) Campos de Diseño en filas con precinto MSTMUE
    v_de_diseno := coalesce(old.datos ->> 7, '') ~* '^\s*MSTMUE\d+\s*$';
    if v_de_diseno then
        foreach v_i in array v_campos_diseno loop
            if coalesce(old.datos ->> v_i, '') is distinct from coalesce(new.datos ->> v_i, '') then
                raise exception 'El campo % de % viene del inventario de Diseño y no se edita en patronaje. Corrígelo en el formulario de Diseño y recarga esta página con Ctrl+Shift+R.',
                    v_nombres[v_i + 1], old.precinto
                    using errcode = 'P0001';
            end if;
        end loop;
    end if;

    return new;
end;
$$;

-- Nombre con "bloqueo" para que corra ANTES que trg_dpto_tecnico_genero (orden alfabético)
drop trigger if exists trg_dpto_tecnico_bloqueo_diseno on public.dpto_tecnico;
create trigger trg_dpto_tecnico_bloqueo_diseno
    before update of datos, precinto on public.dpto_tecnico
    for each row execute function public.trg_bloquear_campos_diseno();

commit;

-- Verificación (solo lectura): deben salir los 3 triggers activos de dpto_tecnico
select tgname as trigger, case tgenabled when 'O' then 'activo' else 'INACTIVO' end as estado
  from pg_trigger
 where tgrelid = 'public.dpto_tecnico'::regclass and not tgisinternal
 order by tgname;

-- =====================================================================
-- FILAS QUE HOY NO COINCIDEN CON EL INVENTARIO (revisión manual)
-- =====================================================================
-- Al 2026-11-25 eran 23. Corregir en Diseño o, si el error está en patronaje,
-- un administrador desde el SQL Editor (el bloqueo no aplica ahí).
--   with dt as (select id, upper(btrim(precinto)) p, datos from public.dpto_tecnico
--               where coalesce(btrim(precinto),'') <> '' and upper(btrim(precinto)) <> 'SIN PRECINTO')
--   select dt.p as precinto, dt.datos->>8 as ref_patronaje,
--          (select string_agg(distinct coalesce(referencia,'?'), ' | ') from public.prendas pr
--            where upper(btrim(pr.precinto)) = dt.p) as ref_inventario
--     from dt
--    where not exists (select 1 from public.prendas pr where upper(btrim(pr.precinto)) = dt.p
--                        and upper(btrim(coalesce(pr.referencia,''))) = upper(btrim(coalesce(dt.datos->>8,''))))
--    order by 3 nulls first, 1;
--
-- VOLVER ATRÁS
--   drop trigger if exists trg_dpto_tecnico_bloqueo_diseno on public.dpto_tecnico;
