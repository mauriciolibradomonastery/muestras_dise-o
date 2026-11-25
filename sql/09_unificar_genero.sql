-- =====================================================================
-- 09 · UNIFICAR GÉNERO  ·  Monastery · Diseño + Dpto. Técnico
-- ---------------------------------------------------------------------
-- QUÉ HACE
--   1. Respalda el género actual de las tres tablas (esquema respaldo).
--   2. Crea normalizar_genero(): convierte cualquier escritura a uno de
--      los 4 valores oficiales:  MEN · WOMEN · UNISEX · KIDS
--        Women, WOMAN, FEMENINO, Mujer, Dama...   → WOMEN
--        Men, MAN, MASCULINO, Hombre, Caballero... → MEN
--        Unisex                                    → UNISEX
--        Kids, Niño, Niña, Infantil...             → KIDS
--      Un valor desconocido NO se borra: se deja en MAYÚSCULAS para revisarlo.
--   3. Unifica los datos existentes de:
--        prendas.genero · dpto_tecnico.datos[3] · dpto_tecnico_historico.genero
--   4. Instala triggers para que todo lo que se guarde DESDE AHORA quede
--      unificado, venga de la página que venga.
--
-- POR QUÉ CON TRIGGER Y NO SOLO EN LA PÁGINA
--   Hoy el género entra por formulario.html, por "Importar desde Diseño",
--   por la celda de patronaje (texto libre) y por importaciones de Excel.
--   Corregir cada página deja huecos; el trigger es una sola puerta que
--   cubre todos los caminos (como un portero en la entrada del edificio).
--
-- EFECTO EN REPORTES
--   reportes.html filtra "Solo Women" comparando con WOMEN: las prendas
--   guardadas como FEMENINO quedaban fuera. Tras este script entran.
--
-- Idempotente: se puede ejecutar varias veces. Ejecutar completo.
-- Los cambios en dpto_tecnico quedan en el historial (dpto_tecnico_cambios).
-- =====================================================================

begin;

-- 1) Respaldo (solo la primera vez: si ya existe, no se sobrescribe) ----
create table if not exists respaldo.genero_prendas_20261125 as
    select id, genero from public.prendas;
create table if not exists respaldo.genero_dpto_tecnico_20261125 as
    select id, datos ->> 3 as genero from public.dpto_tecnico;
create table if not exists respaldo.genero_historico_20261125 as
    select id, genero from public.dpto_tecnico_historico;

-- 2) Función de normalización -----------------------------------------
create or replace function public.normalizar_genero(p_valor text)
returns text
language sql
immutable
set search_path = public
as $$
    select case
        when p_valor is null then null
        when btrim(p_valor) = '' then ''
        else case upper(translate(btrim(p_valor), 'áéíóúÁÉÍÓÚ', 'aeiouAEIOU'))
            when 'WOMEN'      then 'WOMEN'
            when 'WOMAN'      then 'WOMEN'
            when 'FEMENINO'   then 'WOMEN'
            when 'FEMENINA'   then 'WOMEN'
            when 'MUJER'      then 'WOMEN'
            when 'DAMA'       then 'WOMEN'
            when 'MEN'        then 'MEN'
            when 'MAN'        then 'MEN'
            when 'MASCULINO'  then 'MEN'
            when 'HOMBRE'     then 'MEN'
            when 'CABALLERO'  then 'MEN'
            when 'UNISEX'     then 'UNISEX'
            when 'KIDS'       then 'KIDS'
            when 'KID'        then 'KIDS'
            when 'NIÑO'       then 'KIDS'
            when 'NIÑA'       then 'KIDS'
            when 'NIÑOS'      then 'KIDS'
            when 'INFANTIL'   then 'KIDS'
            -- Desconocido: no se pierde, queda en mayúsculas para revisarlo
            else upper(btrim(p_valor))
        end
    end
$$;

-- 3) Unificar datos existentes (solo filas que cambian) ----------------
update public.prendas
   set genero = public.normalizar_genero(genero)
 where genero is distinct from public.normalizar_genero(genero);

update public.dpto_tecnico
   set datos = jsonb_set(datos, '{3}', to_jsonb(public.normalizar_genero(datos ->> 3)), false)
 where jsonb_typeof(datos) = 'array'
   and jsonb_array_length(datos) > 3
   and datos ->> 3 is distinct from public.normalizar_genero(datos ->> 3);

update public.dpto_tecnico_historico
   set genero = public.normalizar_genero(genero)
 where genero is distinct from public.normalizar_genero(genero);

-- 4) Triggers: todo lo nuevo entra unificado ---------------------------
create or replace function public.trg_normalizar_genero_prendas()
returns trigger language plpgsql set search_path = public as $$
begin
    new.genero := public.normalizar_genero(new.genero);
    return new;
end;
$$;

create or replace function public.trg_normalizar_genero_dpto()
returns trigger language plpgsql set search_path = public as $$
begin
    if jsonb_typeof(new.datos) = 'array' and jsonb_array_length(new.datos) > 3
       and new.datos ->> 3 is distinct from public.normalizar_genero(new.datos ->> 3) then
        new.datos := jsonb_set(new.datos, '{3}', to_jsonb(public.normalizar_genero(new.datos ->> 3)), false);
    end if;
    return new;
end;
$$;

drop trigger if exists trg_prendas_genero on public.prendas;
create trigger trg_prendas_genero
    before insert or update of genero on public.prendas
    for each row execute function public.trg_normalizar_genero_prendas();

drop trigger if exists trg_dpto_tecnico_genero on public.dpto_tecnico;
create trigger trg_dpto_tecnico_genero
    before insert or update of datos on public.dpto_tecnico
    for each row execute function public.trg_normalizar_genero_dpto();

commit;

-- 5) Verificación (solo lectura) ----------------------------------------
-- Debe mostrar únicamente MEN, WOMEN, UNISEX, KIDS y vacío/null.
select 'prendas' as tabla, coalesce(genero, '(null)') as genero, count(*) as filas from public.prendas group by 2
union all
select 'dpto_tecnico', coalesce(datos ->> 3, '(null)'), count(*) from public.dpto_tecnico group by 2
union all
select 'historico', coalesce(genero, '(null)'), count(*) from public.dpto_tecnico_historico group by 2
order by 1, 3 desc;

-- =====================================================================
-- VOLVER ATRÁS (solo si algo saliera mal)
-- =====================================================================
--   drop trigger if exists trg_prendas_genero on public.prendas;
--   drop trigger if exists trg_dpto_tecnico_genero on public.dpto_tecnico;
--   update public.prendas p set genero = r.genero
--     from respaldo.genero_prendas_20261125 r where r.id = p.id;
--   update public.dpto_tecnico d set datos = jsonb_set(d.datos, '{3}', to_jsonb(coalesce(r.genero, '')), false)
--     from respaldo.genero_dpto_tecnico_20261125 r where r.id = d.id;
--   update public.dpto_tecnico_historico h set genero = r.genero
--     from respaldo.genero_historico_20261125 r where r.id = h.id;
