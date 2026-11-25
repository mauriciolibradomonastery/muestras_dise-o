-- =====================================================================
-- 11 · ACTUALIZAR DESDE DISEÑO  ·  Monastery · Dpto. Técnico
-- ---------------------------------------------------------------------
-- QUÉ HACE
--   Crea la función actualizar_desde_diseno(p_ids, p_aplicar) que usa el botón
--   "🔄 Actualizar desde Diseño" de patronaje.html:
--     · p_aplicar = false → solo COMPARA y devuelve las diferencias (vista previa).
--     · p_aplicar = true  → copia a dpto_tecnico los datos actuales del inventario.
--   Campos que copia (los mismos que "Importar desde Diseño"):
--     3 GÉNERO ← genero             4 PROVEEDOR ← proveedor
--     5 PAÍS ← paisOrigen           6 COLECCIÓN ← coleccion 8 REFERENCIA ← referencia
--     9 TALLA ← talla               10 TIPO DE MUESTRA ← clasificacion
--     11 PINTA ← color              12 CANTIDAD ← cantidad  13 DESCRIPCIÓN ← linea
--   NO copia la FOTO (en el inventario sigue en base64; la sube la página al importar),
--   ni toca el PRECINTO, ni el DISEÑADOR.
--
-- DISEÑADOR (decidido 2026-11-25): "registradoPor" en Diseño es quien REGISTRÓ la muestra,
--   no necesariamente quien la diseñó. Por eso DISEÑADOR queda LIBRE en patronaje:
--   se quita del bloqueo (trigger) y de la sincronización. La importación lo sigue
--   pre-llenando con registradoPor como sugerencia editable.
--
-- POR QUÉ ASÍ
--   · La copia se hace EN EL SERVIDOR leyendo prendas: la página no manda los valores,
--     así nadie puede usar el botón para meter datos que no estén en Diseño.
--   · El trigger de bloqueo (script 10) impide que la web cambie esos campos; esta
--     función es la única puerta autorizada: activa una marca local de la transacción
--     (app.sync_diseno) que el trigger reconoce.
--   · NUNCA borra: si Diseño tiene el campo vacío, se conserva el valor de patronaje
--     (ej. 2 filas con PROVEEDOR vacío en Diseño).
--   · Si un precinto está repetido en el inventario, usa el registro más reciente
--     (fechaServidor), igual que la importación.
--   · Cada cambio queda en el historial (dpto_tecnico_cambios) con el usuario y la hora.
--
-- Idempotente. Ejecutar completo en Supabase → SQL Editor.
-- =====================================================================

begin;

-- 1) El trigger de bloqueo deja pasar la sincronización autorizada ------
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
    v_campos_diseno constant int[] := array[0, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13];   -- sin 2 DISEÑADOR
    v_de_diseno boolean;
    v_i int;
begin
    -- Sincronización autorizada por actualizar_desde_diseno (marca local de la transacción)
    if current_setting('app.sync_diseno', true) = 'on' then
        return new;
    end if;
    -- Solo peticiones de la web; el SQL Editor y procesos internos pasan
    if coalesce(auth.jwt() ->> 'role', '') <> 'authenticated' then
        return new;
    end if;
    if jsonb_typeof(old.datos) <> 'array' or jsonb_typeof(new.datos) <> 'array' then
        return new;
    end if;

    if coalesce(old.datos ->> 7, '') is distinct from coalesce(new.datos ->> 7, '')
       or coalesce(old.precinto, '') is distinct from coalesce(new.precinto, '') then
        raise exception 'No se puede cambiar el PRECINTO de una muestra (%). El precinto solo entra con "Importar desde Diseño". Recarga la página con Ctrl+Shift+R.',
            coalesce(old.precinto, '(vacío)')
            using errcode = 'P0001';
    end if;

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

-- 2) Función de comparación / sincronización ------------------------------
create or replace function public.actualizar_desde_diseno(p_ids uuid[], p_aplicar boolean default false)
returns table (fila_id uuid, precinto text, indice int, campo text, valor_actual text, valor_diseno text)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_nombres constant text[] := array[
        'FOTO', 'FECHA DE INGRESO', 'DISEÑADOR', 'GÉNERO', 'PROVEEDOR', 'PAÍS', 'COLECCIÓN',
        'PRECINTO', 'NOMBRE / REFERENCIA', 'TALLA', 'TIPO DE MUESTRA', 'PINTA', 'CANTIDAD',
        'DESCRIPCIÓN PRENDA'];
    v_indices constant int[] := array[3, 4, 5, 6, 8, 9, 10, 11, 12, 13];   -- sin 2 DISEÑADOR
    v_fila   record;
    v_prenda record;
    v_nuevo  text[];
    v_datos  jsonb;
    v_cambio boolean;
    v_i      int;
    v_actual text;
begin
    -- Solo usuarios con sesión (o un administrador en el SQL Editor)
    if coalesce(auth.jwt() ->> 'role', '') = 'anon' then
        raise exception 'Debes iniciar sesión para actualizar desde Diseño.' using errcode = '42501';
    end if;
    if p_ids is null or cardinality(p_ids) = 0 then
        return;
    end if;
    if cardinality(p_ids) > 1000 then
        raise exception 'Máximo 1000 filas por vez (llegaron %).', cardinality(p_ids);
    end if;

    for v_fila in
        select d.id, d.precinto, d.datos
          from public.dpto_tecnico d
         where d.id = any (p_ids)
           and jsonb_typeof(d.datos) = 'array'
           and coalesce(d.datos ->> 7, '') ~* '^\s*MSTMUE\d+\s*$'
         order by d.id
         for update                       -- nadie más guarda estas filas mientras se comparan/copian
    loop
        -- Registro del inventario: el más reciente si el precinto está repetido
        -- Solo las columnas necesarias: fotoUrl es base64 pesado y volvería lenta la consulta
        select p.genero, p.proveedor, p."paisOrigen", p.coleccion, p.referencia, p.talla,
               p.clasificacion, p.color, p.cantidad, p.linea
          into v_prenda
          from public.prendas p
         where upper(btrim(p.precinto)) = upper(btrim(v_fila.datos ->> 7))
         order by p."fechaServidor" desc nulls last
         limit 1;

        if not found then
            fila_id := v_fila.id; precinto := v_fila.precinto; indice := null;
            campo := 'NO EXISTE EN DISEÑO'; valor_actual := null; valor_diseno := null;
            return next;
            continue;
        end if;

        -- Valores de Diseño en el mismo orden que v_indices
        v_nuevo := array[
            coalesce(public.normalizar_genero(v_prenda.genero), ''),
            coalesce(v_prenda.proveedor, ''),
            coalesce(v_prenda."paisOrigen", ''),
            coalesce(v_prenda.coleccion, ''),
            coalesce(v_prenda.referencia, ''),
            coalesce(v_prenda.talla, ''),
            coalesce(v_prenda.clasificacion, ''),
            coalesce(v_prenda.color, ''),
            coalesce(v_prenda.cantidad::text, ''),
            coalesce(v_prenda.linea, '')];

        v_datos := v_fila.datos;
        v_cambio := false;
        for n in 1 .. cardinality(v_indices) loop
            v_i := v_indices[n];
            v_actual := coalesce(v_fila.datos ->> v_i, '');
            -- Nunca borrar un dato con un vacío de Diseño: si el inventario no tiene el valor
            -- (ej. 108 filas sin DISEÑADOR en Diseño), se conserva lo que tiene patronaje.
            continue when btrim(v_nuevo[n]) = '';
            if v_actual is distinct from v_nuevo[n] then
                fila_id := v_fila.id; precinto := v_fila.precinto; indice := v_i;
                campo := v_nombres[v_i + 1]; valor_actual := v_actual; valor_diseno := v_nuevo[n];
                return next;
                v_datos := jsonb_set(v_datos, array[v_i::text], to_jsonb(v_nuevo[n]), false);
                v_cambio := true;
            end if;
        end loop;

        if p_aplicar and v_cambio then
            perform set_config('app.sync_diseno', 'on', true);
            update public.dpto_tecnico set datos = v_datos where id = v_fila.id;
            perform set_config('app.sync_diseno', 'off', true);
        end if;
    end loop;
end;
$$;

-- Índice para buscar el precinto en el inventario sin recorrer toda la tabla
create index if not exists prendas_precinto_norm_idx
    on public.prendas (upper(btrim(precinto)), "fechaServidor" desc);

revoke all on function public.actualizar_desde_diseno(uuid[], boolean) from public, anon;
grant execute on function public.actualizar_desde_diseno(uuid[], boolean) to authenticated;

commit;

-- 3) Verificación (solo lectura) ---------------------------------------
-- Vista previa de TODAS las diferencias actuales (no cambia nada):
select precinto, campo, valor_actual, valor_diseno
  from public.actualizar_desde_diseno((select array_agg(id) from public.dpto_tecnico), false)
 order by precinto, indice nulls first;

-- VOLVER ATRÁS
--   drop function if exists public.actualizar_desde_diseno(uuid[], boolean);
--   (y volver a ejecutar sql/10_bloqueo_campos_diseno.sql para quitar la marca app.sync_diseno del trigger)
