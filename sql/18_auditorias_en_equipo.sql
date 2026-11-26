-- =====================================================================
-- 18 · AUDITORÍAS EN EQUIPO: cualquier auditora o jefe puede continuar una auditoría
--      Monastery · Auditorías  (decidido 2026-11-26)
-- ---------------------------------------------------------------------
-- REGLA DE NEGOCIO
--   Las auditorías se hacen en conjunto: una puede estar asignada a Carolina y la
--   termina otra auditora. Antes solo podían EDITAR la auditora asignada, quien la
--   programó o un jefe; las demás auditoras recibían "No tienes permiso para editar".
--
-- QUÉ CAMBIA
--   · EDITAR (datos de la auditoría, cantidades, defectos, medidas, pruebas y evidencias):
--     cualquier miembro ACTIVO del equipo de auditoría (tabla auditoria_usuarios,
--     rol 'auditora' o 'jefe').
--   · La función guardar_detalle_auditoria (script 13) usa la misma regla.
--
-- QUÉ NO CAMBIA
--   · ELIMINAR una auditoría: sigue igual (auditora asignada, quien la programó o jefe).
--   · PROGRAMAR una auditoría: sigue igual.
--   · Personas de otras áreas (Diseño, Patronaje) pueden VER pero NO editar auditorías.
--
-- Idempotente. Ejecutar completo en Supabase → SQL Editor.
-- =====================================================================

begin;

-- 1) ¿La persona con sesión es del equipo de auditoría? ------------------
create or replace function public.es_equipo_auditoria()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select exists (select 1 from public.auditoria_usuarios
                    where id = auth.uid() and activo and rol in ('auditora', 'jefe'));
$$;
revoke all on function public.es_equipo_auditoria() from public, anon;
grant execute on function public.es_equipo_auditoria() to authenticated;

-- 2) Editar la auditoría -------------------------------------------------
drop policy if exists "Editar la propia auditoria" on public.auditorias;
drop policy if exists "Editar auditorias (equipo)" on public.auditorias;
create policy "Editar auditorias (equipo)"
    on public.auditorias for update to authenticated
    using (public.es_equipo_auditoria())
    with check (public.es_equipo_auditoria());

-- 3) Editar lo que cuelga de la auditoría (cantidades, defectos, medidas, pruebas, evidencias)
do $$
declare t text;
begin
    foreach t in array array['auditoria_cantidades', 'auditoria_defectos', 'auditoria_medidas',
                             'auditoria_pruebas', 'auditoria_evidencias'] loop
        execute format('drop policy if exists "Editar hijos propios" on public.%I', t);
        execute format('drop policy if exists "Editar hijos (equipo)" on public.%I', t);
        execute format('create policy "Editar hijos (equipo)" on public.%I for all to authenticated
                          using (public.es_equipo_auditoria())
                          with check (public.es_equipo_auditoria())', t);
    end loop;
end $$;

-- 4) La función de guardado del script 13 usa la misma regla ---------------
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
    -- Permiso explícito (script 18): cualquier auditora o jefe activo del equipo.
    -- El SQL Editor (sin sesión web) no pasa por aquí.
    if coalesce(auth.jwt() ->> 'role', '') = 'authenticated' and not public.es_equipo_auditoria() then
        raise exception 'No tienes permiso para editar auditorías: solo el equipo de auditoría (auditoras y jefes activos). Pide a un jefe que te agregue al equipo.'
            using errcode = '42501';
    end if;
    if (p_cantidades is not null and jsonb_typeof(p_cantidades) <> 'array')
       or (p_defectos is not null and jsonb_typeof(p_defectos) <> 'array')
       or (p_pruebas  is not null and jsonb_typeof(p_pruebas)  <> 'array') then
        raise exception 'Cantidades, defectos y pruebas deben ser arreglos JSON (o null para no tocarlos).';
    end if;

    perform pg_advisory_xact_lock(hashtext('auditoria_detalle'), p_auditoria_id::int);

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
select tablename, policyname, cmd from pg_policies
 where schemaname = 'public' and (tablename = 'auditorias' or tablename in
       ('auditoria_cantidades','auditoria_defectos','auditoria_medidas','auditoria_pruebas','auditoria_evidencias'))
   and cmd in ('UPDATE', 'ALL', 'DELETE')
 order by tablename, cmd;

-- =====================================================================
-- VOLVER ATRÁS: volver a crear las políticas anteriores
--   using/with check = ((auditora_id = auth.uid()) or (programada_por = auth.uid()) or es_jefe_auditoria())
--   en auditorias (UPDATE) y, en las 5 tablas hijas (ALL),
--   exists (select 1 from auditorias a where a.id = <tabla>.auditoria_id and (...misma regla...)),
--   y volver a aplicar sql/13_guardar_detalle_auditoria.sql.
-- =====================================================================
