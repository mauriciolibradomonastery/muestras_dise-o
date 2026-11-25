-- =====================================================================
-- 13 · GUARDAR CANTIDADES, DEFECTOS Y PRUEBAS EN UNA SOLA TRANSACCIÓN  ·  Monastery
-- ---------------------------------------------------------------------
-- PROBLEMA QUE CORRIGE (igual que el script 12 con las medidas)
--   auditoria.html, revision3.html y proceso.html guardaban cantidades, defectos y
--   pruebas con delete() y luego insert() por separado. Si el insert fallaba, esa
--   parte de la auditoría quedaba vacía. proceso.html además no revisaba el error
--   y marcaba la auditoría como FINALIZADA aunque las pruebas no se hubieran guardado.
--
-- QUÉ HACE
--   guardar_detalle_auditoria(id, cantidades, defectos, pruebas, solo_pruebas)
--   reemplaza las tres partes dentro de UNA transacción: o queda todo o nada.
--     · Un parámetro en NULL = esa tabla NO se toca (p. ej. setPrueba solo manda pruebas).
--     · Un arreglo vacío [] = se borran todas las filas de esa parte (igual que antes).
--     · p_solo_pruebas (lista de nombres): solo se reemplazan las pruebas con esos
--       nombres; las demás se conservan (lo usa revision3 para los procesos externos).
--   Devuelve cuántas filas quedaron de cada parte.
--
-- PERMISOS
--   security invoker: aplica las políticas RLS de hoy ("Editar hijos propios":
--   auditora, quien programó o jefe de auditoría). Sin permiso, falla y no borra nada.
--
-- Idempotente. Ejecutar completo en Supabase → SQL Editor.
-- =====================================================================

begin;

create or replace function public.guardar_detalle_auditoria(
    p_auditoria_id bigint,
    p_cantidades   jsonb  default null,
    p_defectos     jsonb  default null,
    p_pruebas      jsonb  default null,
    p_solo_pruebas text[] default null)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
    v_n int;
    v_resultado jsonb := '{}'::jsonb;
begin
    if p_auditoria_id is null then
        raise exception 'Falta el id de la auditoría.';
    end if;
    if not exists (select 1 from public.auditorias where id = p_auditoria_id) then
        raise exception 'La auditoría % no existe o no tienes acceso.', p_auditoria_id;
    end if;
    -- Permiso explícito (misma regla que la política "Editar hijos propios"). Sin esto, alguien
    -- sin permiso que mandara una lista vacía no cambiaba nada pero tampoco recibía error, y la
    -- página creía que había guardado. El SQL Editor (sin sesión web) no pasa por aquí.
    if coalesce(auth.jwt() ->> 'role', '') = 'authenticated'
       and not exists (select 1 from public.auditorias a
                        where a.id = p_auditoria_id
                          and (a.auditora_id = auth.uid() or a.programada_por = auth.uid() or public.es_jefe_auditoria())) then
        raise exception 'No tienes permiso para editar la auditoría %.', p_auditoria_id using errcode = '42501';
    end if;
    if (p_cantidades is not null and jsonb_typeof(p_cantidades) <> 'array')
       or (p_defectos is not null and jsonb_typeof(p_defectos) <> 'array')
       or (p_pruebas  is not null and jsonb_typeof(p_pruebas)  <> 'array') then
        raise exception 'Cantidades, defectos y pruebas deben ser arreglos JSON (o null para no tocarlos).';
    end if;

    -- Dos guardados de la misma auditoría al mismo tiempo se hacen uno detrás del otro
    perform pg_advisory_xact_lock(hashtext('auditoria_detalle'), p_auditoria_id::int);

    -- Cantidades --------------------------------------------------------------
    if p_cantidades is not null then
        delete from public.auditoria_cantidades where auditoria_id = p_auditoria_id;
        insert into public.auditoria_cantidades (auditoria_id, color, talla, cantidad)
        select p_auditoria_id, c ->> 'color', c ->> 'talla', coalesce((c ->> 'cantidad')::numeric, 0)
          from jsonb_array_elements(p_cantidades) c;
        get diagnostics v_n = row_count;
        if v_n <> jsonb_array_length(p_cantidades) then
            raise exception 'Solo se guardaron % de % cantidades; no se cambió nada.', v_n, jsonb_array_length(p_cantidades);
        end if;
        v_resultado := v_resultado || jsonb_build_object('cantidades', v_n);
    end if;

    -- Defectos ----------------------------------------------------------------
    if p_defectos is not null then
        delete from public.auditoria_defectos where auditoria_id = p_auditoria_id;
        insert into public.auditoria_defectos (auditoria_id, severidad, defecto, familia, color, talla, cantidad)
        select p_auditoria_id, d ->> 'severidad', d ->> 'defecto', d ->> 'familia', d ->> 'color', d ->> 'talla',
               coalesce((d ->> 'cantidad')::numeric, 0)
          from jsonb_array_elements(p_defectos) d;
        get diagnostics v_n = row_count;
        if v_n <> jsonb_array_length(p_defectos) then
            raise exception 'Solo se guardaron % de % defectos; no se cambió nada.', v_n, jsonb_array_length(p_defectos);
        end if;
        v_resultado := v_resultado || jsonb_build_object('defectos', v_n);
    end if;

    -- Pruebas -----------------------------------------------------------------
    if p_pruebas is not null then
        if p_solo_pruebas is null then
            delete from public.auditoria_pruebas where auditoria_id = p_auditoria_id;
        else
            delete from public.auditoria_pruebas where auditoria_id = p_auditoria_id and prueba = any (p_solo_pruebas);
        end if;
        insert into public.auditoria_pruebas (auditoria_id, prueba, resultado, observacion)
        select p_auditoria_id, p ->> 'prueba', p ->> 'resultado', p ->> 'observacion'
          from jsonb_array_elements(p_pruebas) p;
        get diagnostics v_n = row_count;
        if v_n <> jsonb_array_length(p_pruebas) then
            raise exception 'Solo se guardaron % de % pruebas; no se cambió nada.', v_n, jsonb_array_length(p_pruebas);
        end if;
        v_resultado := v_resultado || jsonb_build_object('pruebas', v_n);
    end if;

    return v_resultado;
end;
$$;

revoke all on function public.guardar_detalle_auditoria(bigint, jsonb, jsonb, jsonb, text[]) from public, anon;
grant execute on function public.guardar_detalle_auditoria(bigint, jsonb, jsonb, jsonb, text[]) to authenticated;

commit;

-- Verificación (solo lectura)
select proname as funcion, case when prosecdef then 'security definer' else 'security invoker' end as seguridad
  from pg_proc where proname = 'guardar_detalle_auditoria';

-- VOLVER ATRÁS
--   drop function if exists public.guardar_detalle_auditoria(bigint, jsonb, jsonb, jsonb, text[]);
--   (y volver a publicar la versión anterior de auditoria.html, revision3.html y proceso.html)
