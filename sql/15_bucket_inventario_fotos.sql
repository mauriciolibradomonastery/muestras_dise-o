-- =====================================================================
-- 15 · ALMACENAMIENTO DE FOTOS DEL INVENTARIO (bucket inventario-fotos)  ·  Monastery
-- ---------------------------------------------------------------------
-- QUÉ HACE
--   Crea el bucket de Supabase Storage "inventario-fotos" para las fotos de las
--   muestras de Diseño (tabla prendas). Desde el paso 3.1a, formulario.html y la
--   edición en dashboard.html / salidas.html suben la foto aquí y en prendas.fotoUrl
--   guardan solo el enlace, en vez de la imagen completa en base64.
--
-- POR QUÉ
--   Las 345 fotos en base64 dentro de la tabla suman ~9 MB que se descargan cada vez
--   que alguien abre el dashboard, las salidas o los reportes (select('*')).
--
-- CONFIGURACIÓN (igual que los buckets que ya existen)
--   · Público para leer (como dpto-tecnico, fotos-referencias...). Pasarlo a privado
--     es el paso 3.2, para todos los buckets a la vez.
--   · Solo usuarios con sesión pueden SUBIR. Nadie puede modificar ni borrar desde
--     la web (cada foto nueva lleva un nombre único; la anterior queda como historial).
--   · Límite 2 MB por archivo y solo imágenes (la página ya comprime a ~26 KB).
--
-- Idempotente. Ejecutar completo en Supabase → SQL Editor.
-- =====================================================================

begin;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('inventario-fotos', 'inventario-fotos', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
   set public = excluded.public,
       file_size_limit = excluded.file_size_limit,
       allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "inventario subir fotos" on storage.objects;
create policy "inventario subir fotos"
    on storage.objects for insert to authenticated
    with check (bucket_id = 'inventario-fotos');

drop policy if exists "inventario leer fotos" on storage.objects;
create policy "inventario leer fotos"
    on storage.objects for select to authenticated
    using (bucket_id = 'inventario-fotos');

commit;

-- Verificación (solo lectura)
select id, public, file_size_limit, allowed_mime_types from storage.buckets where id = 'inventario-fotos';
select policyname, cmd from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'inventario %';

-- VOLVER ATRÁS (solo si no hay fotos subidas todavía)
--   drop policy if exists "inventario subir fotos" on storage.objects;
--   drop policy if exists "inventario leer fotos" on storage.objects;
--   delete from storage.buckets where id = 'inventario-fotos';
