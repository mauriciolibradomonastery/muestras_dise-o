-- =====================================================================
-- 12 · GUARDAR MEDIDAS DE AUDITORÍA EN UNA SOLA TRANSACCIÓN  ·  Monastery
-- ---------------------------------------------------------------------
-- PROBLEMA QUE CORRIGE
--   auditoria.html y revision3.html guardaban las medidas en dos pasos separados:
--     1) delete() de todas las medidas de la auditoría (sin revisar el error)
--     2) insert() de las medidas nuevas
--   Si el paso 2 fallaba (red, sesión, un dato inválido), la auditoría quedaba
--   SIN medidas en la base. Además los errores de red se tragaban en silencio.
--
-- QUÉ HACE
--   guardar_medidas_auditoria(p_auditoria_id, p_medidas) borra e inserta dentro de
--   UNA transacción: o queda todo guardado o no cambia nada (como una transferencia
--   bancaria: no puede salir la plata de una cuenta sin entrar en la otra).
--   Devuelve cuántas medidas quedaron guardadas.
--
-- PERMISOS
--   security invoker: aplica las mismas políticas RLS de hoy en auditoria_medidas
--   ("Editar hijos propios": auditora, quien la programó o jefe de auditoría).
--   Si no tiene permiso, el insert falla y se deshace todo (no borra nada).
--
-- Idempotente. Ejecutar completo en Supabase → SQL Editor.
-- =====================================================================

begin;

create or replace function public.guardar_medidas_auditoria(p_auditoria_id bigint, p_medidas jsonb)
returns integer
language plpgsql
security invoker
set search_path = public
as $$
declare
    v_esperadas int;
    v_insertadas int;
begin
    if p_auditoria_id is null then
        raise exception 'Falta el id de la auditoría.';
    end if;
    if p_medidas is null or jsonb_typeof(p_medidas) <> 'array' then
        raise exception 'p_medidas debe ser un arreglo JSON de medidas.';
    end if;
    v_esperadas := jsonb_array_length(p_medidas);
    if v_esperadas > 5000 then
        raise exception 'Demasiadas medidas en un solo guardado (%).', v_esperadas;
    end if;
    if not exists (select 1 from public.auditorias where id = p_auditoria_id) then
        raise exception 'La auditoría % no existe o no tienes acceso.', p_auditoria_id;
    end if;

    -- Dos guardados de la misma auditoría al mismo tiempo se hacen uno detrás del otro
    perform pg_advisory_xact_lock(hashtext('auditoria_medidas'), p_auditoria_id::int);

    delete from public.auditoria_medidas where auditoria_id = p_auditoria_id;

    -- Si una clave no viene en el JSON se usa el mismo valor por defecto que antes
    -- (tolerancia = 0.5); si viene en null, se guarda null, igual que con insert().
    insert into public.auditoria_medidas
        (auditoria_id, punto_medida, talla, medida_teorica, tolerancia, medida_real, cumple,
         tolerancia_neg, tolerancia_pos, descripcion, orden, prenda, color)
    select p_auditoria_id,
           m ->> 'punto_medida',
           m ->> 'talla',
           (m ->> 'medida_teorica')::numeric,
           case when m ? 'tolerancia' then (m ->> 'tolerancia')::numeric else 0.5 end,
           (m ->> 'medida_real')::numeric,
           (m ->> 'cumple')::boolean,
           (m ->> 'tolerancia_neg')::numeric,
           (m ->> 'tolerancia_pos')::numeric,
           m ->> 'descripcion',
           (m ->> 'orden')::int,
           (m ->> 'prenda')::int,
           m ->> 'color'
      from jsonb_array_elements(p_medidas) as m;
    get diagnostics v_insertadas = row_count;

    if v_insertadas <> v_esperadas then
        raise exception 'Solo se pudieron guardar % de % medidas; no se cambió nada.', v_insertadas, v_esperadas;
    end if;

    return v_insertadas;
end;
$$;

revoke all on function public.guardar_medidas_auditoria(bigint, jsonb) from public, anon;
grant execute on function public.guardar_medidas_auditoria(bigint, jsonb) to authenticated;

commit;

-- Verificación (solo lectura)
select proname as funcion, case when prosecdef then 'security definer' else 'security invoker' end as seguridad
  from pg_proc where proname = 'guardar_medidas_auditoria';

-- VOLVER ATRÁS
--   drop function if exists public.guardar_medidas_auditoria(bigint, jsonb);
--   (y volver a publicar la versión anterior de auditoria.html y revision3.html)
