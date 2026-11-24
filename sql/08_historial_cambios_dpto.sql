-- =====================================================================
-- 08 · HISTORIAL DE CAMBIOS DE dpto_tecnico  ·  Monastery · Dpto. Técnico
-- ---------------------------------------------------------------------
-- QUÉ HACE
--   Cada vez que una fila de dpto_tecnico se crea, cambia o se borra, un
--   trigger anota en dpto_tecnico_cambios:
--     · qué campo cambió (índice + nombre de la columna)
--     · valor anterior y valor nuevo
--     · quién lo hizo (correo del usuario) y a qué hora
--   Si se borra una fila, se guarda la fila COMPLETA para poder recuperarla.
--
-- POR QUÉ
--   Hoy la tabla solo guarda el valor actual. Ante un "lo guardé y
--   desapareció" no hay forma de saber si se borró, si nunca llegó o si
--   alguien lo cambió. Con este historial se responde con evidencia.
--
-- NO CAMBIA NADA DE LA PÁGINA: patronaje.html sigue funcionando igual.
--
-- SEGURIDAD
--   · Los usuarios solo pueden LEER el historial; nadie lo puede editar ni
--     borrar desde la web (no hay políticas de escritura).
--   · El trigger escribe con los permisos del dueño de la función
--     (security definer), por eso funciona aunque el usuario no tenga
--     permiso de escritura sobre el historial.
--
-- Se puede ejecutar varias veces sin dañar nada (idempotente).
-- Ejecutar completo en: Supabase → SQL Editor.
-- =====================================================================

begin;

-- 1) Tabla del historial ------------------------------------------------
create table if not exists public.dpto_tecnico_cambios (
    id              bigint generated always as identity primary key,
    fila_id         uuid        not null,           -- dpto_tecnico.id
    precinto        text,
    operacion       text        not null check (operacion in ('INSERT', 'UPDATE', 'DELETE')),
    indice          int,                              -- posición en datos (0–29); null en INSERT/DELETE
    campo           text,                             -- nombre legible de la columna
    valor_anterior  text,
    valor_nuevo     text,
    fila_completa   jsonb,                            -- solo en DELETE: la fila entera para recuperarla
    usuario_id      uuid,
    usuario_email   text,
    cambiado_en     timestamptz not null default now()
);

comment on table public.dpto_tecnico_cambios is
    'Historial automático de cambios de dpto_tecnico (trigger trg_dpto_tecnico_historial). Solo lectura desde la web.';

create index if not exists dpto_tecnico_cambios_fila_idx     on public.dpto_tecnico_cambios (fila_id, cambiado_en desc);
create index if not exists dpto_tecnico_cambios_precinto_idx on public.dpto_tecnico_cambios (precinto, cambiado_en desc);
create index if not exists dpto_tecnico_cambios_fecha_idx    on public.dpto_tecnico_cambios (cambiado_en desc);

-- 2) Permisos: solo lectura para usuarios autenticados ------------------
alter table public.dpto_tecnico_cambios enable row level security;

revoke all on public.dpto_tecnico_cambios from anon;
revoke insert, update, delete, truncate on public.dpto_tecnico_cambios from authenticated;
grant select on public.dpto_tecnico_cambios to authenticated;

drop policy if exists "lectura historial personal" on public.dpto_tecnico_cambios;
create policy "lectura historial personal"
    on public.dpto_tecnico_cambios
    for select
    to authenticated
    using (true);

-- 3) Función del trigger ------------------------------------------------
create or replace function public.registrar_cambio_dpto()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    -- Mismo orden que el arreglo datos (ver CLAUDE.md §3)
    v_nombres constant text[] := array[
        'FOTO', 'FECHA DE INGRESO', 'DISEÑADOR', 'GÉNERO', 'PROVEEDOR', 'PAÍS', 'COLECCIÓN',
        'PRECINTO', 'NOMBRE / REFERENCIA', 'TALLA', 'TIPO DE MUESTRA', 'PINTA', 'CANTIDAD',
        'DESCRIPCIÓN PRENDA', 'ESTADO', 'MEDICIÓN', 'FECHA ENTREGA AUDITORÍA', 'AUDITOR',
        'LEAD TIME AUD', 'INGRESO HÚMEDO', 'SALIDA HÚMEDO', 'RESULTADO', 'MOTIVO 1', 'MOTIVO 2',
        'MOTIVO 3', 'FECHA FINAL', 'LEAD TIME ENTREGA', 'LEAD TIME GENERAL', 'TIPO', 'PDF AUDITORÍA'];
    -- Columnas que la página calcula sola: se derivan de las fechas, registrarlas solo sería ruido
    v_calculadas constant int[] := array[14, 18, 26, 27, 28];
    v_usuario  uuid := auth.uid();
    v_email    text := auth.jwt() ->> 'email';
    v_i        int;
    v_antes    text;
    v_despues  text;
begin
    -- El historial nunca debe impedir guardar: si algo falla aquí, se avisa
    -- en el log de Postgres y el guardado del usuario sigue adelante.
    begin
        if tg_op = 'INSERT' then
            insert into public.dpto_tecnico_cambios (fila_id, precinto, operacion, valor_nuevo, usuario_id, usuario_email)
            values (new.id, new.precinto, 'INSERT', new.precinto, v_usuario, v_email);

        elsif tg_op = 'DELETE' then
            insert into public.dpto_tecnico_cambios (fila_id, precinto, operacion, valor_anterior, fila_completa, usuario_id, usuario_email)
            values (old.id, old.precinto, 'DELETE', old.precinto, to_jsonb(old), v_usuario, v_email);

        elsif new.datos is distinct from old.datos then   -- UPDATE: una fila de historial por campo cambiado
            for v_i in 0..29 loop
                continue when v_i = any (v_calculadas);
                v_antes   := coalesce(old.datos ->> v_i, '');
                v_despues := coalesce(new.datos ->> v_i, '');
                if v_antes is distinct from v_despues then
                    insert into public.dpto_tecnico_cambios
                        (fila_id, precinto, operacion, indice, campo, valor_anterior, valor_nuevo, usuario_id, usuario_email)
                    values
                        (new.id, new.precinto, 'UPDATE', v_i, v_nombres[v_i + 1],
                         left(v_antes, 500), left(v_despues, 500),      -- fotos/PDF en base64 se recortan
                         v_usuario, v_email);
                end if;
            end loop;
        end if;
    exception when others then
        raise warning '[historial] No se registró el cambio de la fila %: %', coalesce(new.id, old.id), sqlerrm;
    end;

    return null;   -- trigger AFTER: el valor de retorno se ignora
end;
$$;

revoke all on function public.registrar_cambio_dpto() from public, anon, authenticated;

-- 4) Trigger ------------------------------------------------------------
drop trigger if exists trg_dpto_tecnico_historial on public.dpto_tecnico;
create trigger trg_dpto_tecnico_historial
    after insert or update or delete on public.dpto_tecnico
    for each row execute function public.registrar_cambio_dpto();

commit;

-- 5) Verificación (solo lectura) ----------------------------------------
-- Debe devolver: el trigger activo, la política de lectura y 0 filas de historial (aún no hay cambios).
select 'trigger'  as objeto, tgname as nombre, case tgenabled when 'O' then 'activo' else 'INACTIVO' end as estado
  from pg_trigger where tgname = 'trg_dpto_tecnico_historial'
union all
select 'politica', policyname, cmd from pg_policies where tablename = 'dpto_tecnico_cambios'
union all
select 'filas en historial', count(*)::text, '' from public.dpto_tecnico_cambios;

-- =====================================================================
-- CONSULTAS DE USO (copiar y pegar cuando se necesiten)
-- =====================================================================
-- Todo lo que le pasó a un precinto:
--   select cambiado_en at time zone 'America/Bogota' as hora_colombia, usuario_email, operacion,
--          campo, valor_anterior, valor_nuevo
--     from public.dpto_tecnico_cambios
--    where precinto = 'MSTMUE11422'
--    order by cambiado_en;
--
-- Campos que alguien VACIÓ (la señal típica de "lo guardé y desapareció"):
--   select cambiado_en at time zone 'America/Bogota' as hora_colombia, usuario_email, precinto,
--          campo, valor_anterior
--     from public.dpto_tecnico_cambios
--    where operacion = 'UPDATE' and valor_anterior <> '' and valor_nuevo = ''
--    order by cambiado_en desc;
--
-- Filas borradas (con la fila completa para recuperarla):
--   select cambiado_en at time zone 'America/Bogota' as hora_colombia, usuario_email, precinto, fila_completa
--     from public.dpto_tecnico_cambios
--    where operacion = 'DELETE'
--    order by cambiado_en desc;
