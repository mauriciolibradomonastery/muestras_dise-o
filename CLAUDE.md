# CLAUDE.md — Sistema de muestras y patronaje (Monastery · Departamento Técnico)

Contexto para Claude Code. Léelo completo antes de tocar código. Responde y comenta en **español**.
Última actualización: 2026-11-25.

## 1. Qué es este proyecto

Sitio web estático (HTML + JavaScript sin framework ni build) para el Departamento Técnico de Monastery
(retail de ropa premium, Colombia). Registra muestras de diseño, hace el seguimiento de patronaje/auditoría
de cada muestra y genera reportes de gestión.

- **Hosting:** GitHub Pages, publica la rama `main` del repo `mauriciolibradomonastery/muestras_dise-o`.
  Cada commit a `main` sale a producción en 1–2 minutos. No hay entorno de pruebas separado.
- **Base de datos:** Supabase (Postgres + Auth + Storage). Proyecto `emljzsxypeqecevffmwr`
  (`monastery_diseño_muestras`, organización de Monastery — no confundir con la cuenta de Alfillabs).
- **Usuarios:** varias personas editan la misma tabla al mismo tiempo. Zona horaria America/Bogota (UTC-5).
- **Dueño:** Mauricio Librado (analista de datos, no desarrollador de tiempo completo). Explica el *porqué*
  de cada cambio con nivel técnico moderado.

## 2. Estructura del repositorio

```
/                       Páginas del módulo de muestras (Diseño)
  index.html            Login general
  menu.html             Menú
  formulario.html       Registro de muestras → tabla `prendas`
  dashboard.html, reportes.html, salidas.html, produccion.html, seguimiento_diseno.html
  sesion.js             Guardián de sesión (compartido)
  utilidades.js         Logger (crearLogger) y crearRecargaAgrupada para Realtime.
                        Lo usan dashboard, reportes y salidas.
  logo.png, fondo.png, favicon.png
/PATRONAJE/             Módulo del Departamento Técnico
  index_patronaje.html  Login de patronaje
  patronaje.html        Tabla de trabajo (la página crítica) → tabla `dpto_tecnico`
  reportes_patronaje.html  Reportes/KPIs (solo lectura)
  sesion.js             Copia del guardián de sesión (mantener igual a la de la raíz)
/auditorias/            Módulo de auditorías (agenda, auditoria, medidas). Revisado solo por logs (§10).
/sql/                   Scripts SQL aplicados (desde el 08). Los anteriores no están en el repo.
/public/                ⚠️ Versiones VIEJAS conectadas a Firebase. No usar. Pendiente de retirar.
```

Nota: `PATRONAJE/fondo.png` no existe (404 inofensivo; el fondo está en la raíz).

## 3. Supabase: tablas y objetos

RLS está **activo** en todas las tablas. Solo el rol `authenticated` tiene acceso. La llave
`sb_publishable_...` en el código es pública por diseño; **nunca** pongas una service_role key en el repo.

| Objeto | Uso | Acceso web |
|---|---|---|
| `public.prendas` | Inventario de muestras (formulario.html). Columnas sueltas: `precinto`, `referencia`, `genero`, `proveedor`, `coleccion`, `cantidad`, `fotoUrl` (aún base64), `fechaServidor` (fecha de registro; **no existe `created_at`**), etc. | lectura/escritura |
| `public.dpto_tecnico` | Tabla de trabajo de patronaje. `id uuid`, `precinto text`, `datos jsonb` (arreglo de 30 posiciones), `created_at`. | lectura/escritura |
| `public.dpto_tecnico_cambios` | **Historial automático** (trigger `trg_dpto_tecnico_historial`): por cada campo cambiado guarda valor anterior, nuevo, usuario y hora; en DELETE guarda la fila completa. No registra columnas calculadas (14, 18, 26, 27, 28). Activo desde 2026-11-24. | **solo SELECT** |
| `public.dpto_tecnico_historico` | Histórico importado del Excel (ene–jul 2026, 1.070 filas, lote `excel_dpto_tecnico_2026_01_a_07`). Columnas de texto con nombres propios (`fecha_ingreso`, `proveedor`, `fecha_final`…). Solo la usa el reporte. | **solo SELECT** |
| `public.festivos` | `fecha date` PK. Festivos de Colombia de lunes a viernes, 2024–2030. | **solo SELECT** |
| `public.actualizar_campos_dpto(p_id uuid, p_cambios jsonb)` | RPC de guardado por campo (ver §5). `security invoker`, ejecutable solo por `authenticated`. Revisada 2026-11-24: correcta. | execute |
| `public.normalizar_genero(text)` | Convierte cualquier escritura de género a `MEN`/`WOMEN`/`UNISEX`/`KIDS`. Desconocido → MAYÚSCULAS, no se borra. | — |
| `trg_dpto_tecnico_bloqueo_diseno` | BEFORE UPDATE: rechaza desde la web cambios al precinto y, en filas `MSTMUE…`, a los campos de Diseño (§6.4). Deja pasar la sincronización autorizada (`app.sync_diseno`). Scripts 10 y 11. | — |
| `public.actualizar_desde_diseno(p_ids uuid[], p_aplicar bool)` | Botón "🔄 Actualizar desde Diseño": compara (`false`) o copia (`true`) desde `prendas` los campos 3–6 y 8–13. Copia en el servidor; nunca borra con un vacío de Diseño; no toca FOTO, PRECINTO ni DISEÑADOR. `security definer`, solo `authenticated`. Script 11. | execute |
| `public.guardar_medidas_auditoria(p_auditoria_id bigint, p_medidas jsonb)` | Auditorías: borra e inserta las medidas en **una sola transacción** (o todo o nada). `security invoker`: aplica las políticas RLS de `auditoria_medidas`. La usan `auditorias/auditoria.html` y `revision3.html`. Script 12. | execute |
| Triggers de género | `trg_prendas_genero` (prendas.genero) y `trg_dpto_tecnico_genero` (dpto_tecnico.datos[3]), BEFORE INSERT/UPDATE. | — |
| esquema `respaldo` | Copias de seguridad: `dpto_tecnico_20261023`, `prendas_20261023`, `genero_prendas_20261125`, `genero_dpto_tecnico_20261125`, `genero_historico_20261125`. No expuesto por la API. | — |
| Storage bucket `dpto-tecnico` | Fotos y PDFs de auditoría (`getPublicUrl`, bucket público — pendiente pasar a privado). | — |

### Mapa del arreglo `dpto_tecnico.datos` (índices 0–29)

```
0 FOTO (URL)            10 TIPO DE MUESTRA        20 SALIDA HÚMEDO
1 FECHA DE INGRESO      11 PINTA (color)          21 RESULTADO ("Cumple"/"No Cumple"/otros)
2 DISEÑADOR             12 CANTIDAD               22 MOTIVO 1
3 GÉNERO (lista)        13 DESCRIPCIÓN PRENDA     23 MOTIVO 2
4 PROVEEDOR             14 ESTADO (calculado)     24 MOTIVO 3
5 PAÍS                  15 MEDICIÓN (fecha)       25 FECHA FINAL
6 COLECCIÓN             16 FECHA ENTREGA AUDIT.   26 LEAD TIME ENTREGA (calculado)
7 PRECINTO              17 AUDITOR                27 LEAD TIME GENERAL (calculado)
8 NOMBRE / REFERENCIA   18 LEAD TIME AUD (calc.)  28 TIPO (calculado/derivado)
9 TALLA                 19 INGRESO HÚMEDO         29 PDF AUDITORÍA (URL)
```

En `patronaje.html` la tabla HTML tiene una columna extra (checkbox) al inicio: la celda `td[i+1]` = `datos[i]`.
`COLUMNAS_CALCULADAS = {14, 18, 26, 27, 28}`.

**Estado:** se deriva de las fechas → sin fechas = Pendiente; con MEDICIÓN = Modelado;
con FECHA ENTREGA AUDITORÍA = Asignado; con FECHA FINAL = Finalizado.

## 4. Convenciones de negocio

- **Precinto:** `MSTMUE` + número, siempre en MAYÚSCULAS. `SIN PRECINTO` es un comodín legítimo
  (insumos, strike offs, pruebas de lavado) y se repite mucho.
- **Un precinto puede repetirse** en `dpto_tecnico` (segundas rondas). NO agregar restricción `unique`;
  la página solo avisa y pregunta al importar.
- **El precinto es el código de enlace con el inventario:** al importar desde Diseño se copian 14 campos
  de `prendas` (incluida la referencia). La copia es única: si Diseño corrige después, patronaje no se entera.
- **Género:** solo `MEN`, `WOMEN`, `UNISEX`, `KIDS` (decidido 2026-11-25). La base lo normaliza sola por
  trigger; formulario.html y patronaje.html ofrecen exactamente esas opciones (en patronaje,
  constante `GENEROS`).
- **Lead time** = días hábiles contando inicio y fin, **sin sábados, domingos ni festivos** (tabla `festivos`).
  Coincide con `DIAS.LAB` del Excel original (verificado 1.070/1.070).
  - Lead time completo (reportes) = FECHA DE INGRESO → FECHA FINAL.
  - Lead time auditoría = MEDICIÓN → FECHA ENTREGA AUDITORÍA.
- **Cantidad:** si está vacía cuenta como 1 unidad en reportes.
- **Proveedores:** formato `NOMBRE/PAIS`. El reporte unifica mayúsculas, tildes (conserva Ñ) y espacios
  alrededor de `/`.
- **Histórico:** todo lo del histórico cuenta como **Finalizado** y se consolida con el sistema
  (sin categoría ni interruptor aparte). El reporte ignora filas del histórico con ingreso ≥ `2026-08-01`
  para no contar doble. Las muestras del sistema anteriores a agosto sí se suman.

## 5. Reglas técnicas que NO se pueden romper

Cada una corrige un bug real que causaba pérdida de datos o cifras erróneas.

1. **Guardado por campo, nunca la fila completa.** `patronaje.html` calcula los campos que el usuario
   cambió (`calcularCambios(local, base)`) y llama `client.rpc('actualizar_campos_dpto', ...)`. La función
   SQL bloquea la fila (`FOR UPDATE`) y aplica solo esos índices. Enviar el arreglo completo con
   `.update({datos})` reintroduce el bug de "lo guardé y desapareció" (un usuario pisaba a otro).
2. **No pasar datos del servidor por el DOM para luego reenviarlos.** El DOM pierde valores
   (un `<select>` sin la opción, un `<input type="date">` con formato raro). Los select de RESULTADO y
   GÉNERO agregan dinámicamente cualquier valor desconocido; las fechas no ISO se muestran como `<input type="text">`.
3. **Fechas como fecha local:** usar `fechaLocal('AAAA-MM-DD')` → `new Date(y, m-1, d)`.
   **Nunca** `new Date('2026-03-16')` (se interpreta UTC y en Colombia cae el día anterior).
4. **Escapar todo lo que va a `innerHTML`:** `esc()` para texto/atributos, `urlSegura()` para `href`/`src`
   (solo `https://` o `data:image|application/pdf`).
5. **Concurrencia acotada:** usar `enLotes(items, limite, tarea)` con `Promise.allSettled`; no lanzar
   cientos de peticiones a la vez.
6. **Nunca tragarse errores de Supabase.** Siempre desestructurar `{ data, error }` y manejar `error`.
   Un error de red no es "no existe".
7. **Reintento ante token:** `conReintentoSesion()` reintenta si el error es de JWT
   ("JWT issued at future", PGRST301/302/303): espera 2 s, reintenta, luego `refreshSession()`.
   Seguro porque el servidor rechaza antes de escribir.
8. **Autoguardado** 5 s después de la última edición; se pausa si un guardado falla
   (`window.ultimoGuardadoFallo`) hasta un guardado manual exitoso.
9. **Sesión:** `sesion.js` cierra por cambio de día o 4 h de inactividad, pero antes llama
   `window.guardarAntesDeSalir()`; si no se pudo guardar, **no cierra**. La página expone
   `window.sbCliente` para que `sesion.js` reutilice el mismo cliente de Supabase.
10. **Supabase devuelve máximo 1000 filas** por consulta: paginar con `.range()` (ver `traerTodo()` en
    formulario.html y la carga de reportes).
11. **Logging:** `console.error/warn` con prefijo de módulo (`[guardar]`, `[importar]`, `[sesion]`,
    `[reportes]`, `[festivos]`, `[historial]`), no `print`/`console.log` sueltos.
12. **Nunca reemplazar la fila completa después de guardar** (bug corregido 2026-11-24). Si otra persona
    cambió campos de la fila, `despuesDeGuardar` reemplaza **solo esas celdas** y **nunca la celda con el
    cursor** (`document.activeElement`). Reemplazar la fila (`replaceWith`) sacaba del DOM la celda donde
    el usuario escribía y lo que tecleaba después se perdía sin aviso.
    - Copiar colecciones vivas con `Array.from(tr.children)` antes de mover celdas (si no, los índices se corren).
    - Los manejadores de celda buscan su fila al momento del evento (`alEditarCelda` → `e.currentTarget.closest('tr')`),
      nunca guardan una referencia a la fila de cuando se crearon.
13. **Los valores de catálogo se normalizan en la base, no solo en la página.** Un trigger es la única puerta
    que cubre todos los caminos de entrada (formulario, importación, celda editable, Excel). Las páginas
    además muestran listas cerradas con los mismos valores. Ejemplo: género (§3, §4).

## 6. Flujo de un precinto

1. `formulario.html` registra la muestra en `prendas` (valida duplicado con `ilike` y pasa a mayúsculas).
2. En `patronaje.html` → "Importar desde Diseño": se pegan precintos, `buscarPrecintoEnDiseno` los busca
   en `prendas`, avisa cuáles ya están en `dpto_tecnico` y cuáles no existen.
   Si el precinto está repetido en `prendas`, toma el registro más reciente por `fechaServidor`.
3. `agregarAPatronajeMulti` sube la foto a Storage (máx. 4 en paralelo), copia 14 campos al arreglo
   `datos` e inserta en `dpto_tecnico`. Las filas nuevas se pintan arriba **sin recargar toda la tabla**
   (recargar borraría ediciones sin guardar).
4. **Bloqueo de campos de Diseño** (decidido 2026-11-25):
   - El PRECINTO no se edita nunca en patronaje (solo entra importando desde Diseño).
   - En filas con precinto `MSTMUE…` no se editan los campos copiados del inventario
     (`CAMPOS_DISENO` = 0, 3–13: foto, género, proveedor, país, colección, precinto, referencia,
     talla, tipo de muestra, pinta, cantidad, descripción). Se corrigen en Diseño y se traen con
     **"🔄 Actualizar desde Diseño"** (vista previa → confirmar).
   - **DISEÑADOR (2) es libre:** en Diseño `registradoPor` es quien *registró* la muestra, no quien la
     diseñó. La importación lo pre-llena como sugerencia; ni el bloqueo ni la sincronización lo tocan.
   - "Fila Manual" crea la fila con `SIN PRECINTO` (referencias sin precinto) y ahí sí se llena todo a mano.
   - La base aplica lo mismo con `trg_dpto_tecnico_bloqueo_diseno` (solo para el rol `authenticated`;
     el SQL Editor puede corregir).

## 7. reportes_patronaje.html

Solo lectura. Carga `festivos` → `dpto_tecnico` (paginado) → `dpto_tecnico_historico` (paginado, convertido
al mismo arreglo de 30 con `historicoADatos`). Todo pasa por `normalizar()` y se filtra en memoria.
Usa Chart.js 4.4.1 (CDN). Filtros por selects, fechas y clic en gráficos (`alternarFiltro`).
Selector Unidades/Muestras (los gráficos de "Unidades por mes" y "por colección" siempre suman Cantidad).
Si el histórico no carga, muestra un aviso rojo (cifras incompletas).

## 8. Cómo probar

- No hay tests automatizados. Probar en una rama y con **Live Server** de VS Code (no `file://`, porque
  `sesion.js` es módulo ES).
- La página local se conecta a la **base real**: usar filas de prueba (ej. precinto `PRUEBA-001`) y borrarlas.
- Para verificar sin red: servir la carpeta y reemplazar los `<script>` de CDN por mocks de
  `window.supabase.createClient` / `Chart` (así se probaron los cambios con Playwright + Chromium).
- Comprobar en la consola del navegador que la versión es la nueva:
  `typeof guardarAntesDeSalir === 'function'` y `typeof alEditarCelda === 'function'`.
- Casos mínimos tras tocar el guardado:
  - dos usuarios editan columnas distintas de la misma fila y ambos cambios persisten;
  - A sigue escribiendo mientras corre el autoguardado y B cambia otra columna de esa fila → no se pierde
    texto, el cursor no sale de la celda y el cambio de B aparece;
  - RESULTADO = `CANCELADO` sobrevive a editar otra celda;
  - lunes→viernes sin festivo = 5.
- SQL: probar primero en una transacción que se aborte sola al final
  (`do $$ begin raise exception 'RESULTADO: %', (...); end $$;`) para ver el resultado sin dejar rastro.

## 9. Despliegue y SQL

- Subir a `main` (o rama + PR). Esperar el check verde de "pages build and deployment" en Actions
  (si se suben archivos en tandas seguidas, GitHub cancela el despliegue anterior: es normal).
  Pedir a los usuarios **Ctrl + Shift + R**.
- Si un cambio de HTML depende de un objeto SQL nuevo, **ejecutar el SQL primero**.
- Cambios de esquema: scripts idempotentes (`create ... if not exists`, `drop policy if exists`),
  dentro de `begin/commit` cuando modifican datos, con respaldo en el esquema `respaldo`, con una consulta
  de verificación al final y con instrucciones para volver atrás. Se guardan en `/sql/`.
  El usuario los ejecuta en el SQL Editor de Supabase, o los aplica Claude con el conector si el usuario
  lo autoriza (el conector pide confirmación en Supabase para cualquier escritura).
- Scripts ya aplicados (en orden): `01_respaldo_y_diagnostico`, `02_guardado_por_campo`,
  `04_prueba_guardado`, `05_tabla_historico`, `06_carga_historico_2026_01_a_07`, renombrado de 4 proveedores,
  borrado de 6 duplicados histórico↔sistema, `07_festivos`, `08_historial_cambios_dpto` (2026-11-24),
  `09_unificar_genero` (2026-11-25), `10_bloqueo_campos_diseno` (2026-11-25), `11_actualizar_desde_diseno` (2026-11-25), `12_guardar_medidas_auditoria` (2026-11-25). (`03_seguridad_rls` no fue necesario.)
- Accesos: GitHub y Supabase deben estar conectados con las cuentas de **Monastery**
  (`mauriciolibradomonastery`). Si la pantalla de autorización muestra "Alfillabs", el navegador tiene
  abierta otra cuenta: usar ventana de incógnito.

## 10. Plan de trabajo (organizado el 2026-11-25)

Cifras tomadas de la base el 2026-11-25. Ir fase por fase; dentro de cada fase, en orden.

### Fase 0 · Operación (lo hace el equipo, sin código)
| # | Tarea | Tamaño | Quién |
|---|---|---|---|
| 0.1 | Revisar con "🔄 Actualizar desde Diseño" las **81 diferencias en 59 muestras** y aplicar las correctas. Casos dudosos (ej. MSTMUE11216 PALICK vs PROTO PRECOTEX) se corrigen primero en Diseño. | 1 sesión | Patronaje + Diseño |
| 0.2 | **8 precintos MSTMUE que no existen en Diseño**: registrarlos o corregir el número. Filas manuales con precinto raro (`2 UNIDADES`, `APL327`, `11369`) → corregir con un administrador. | 8 + 3 filas | Diseño / admin |
| 0.3 | **9 prendas sin género** en el inventario: completarlas en el formulario. | 9 filas | Diseño |
| 0.4 | **2 muestras con ingreso en 2025** (MSTMUE9521 2025-12-15, MSTMUE5383 2025-10-20): corregir el año (FECHA DE INGRESO sí es editable). | 2 filas | Patronaje |
| 0.5 | **Diciembre:** confirmar en `festivos` los festivos de 2027 (cargados hasta 2030). | 5 min | Mauricio |
| 0.6 | Decidir la fórmula de **LEAD TIME GENERAL** (hoy copia LEAD TIME AUD). | decisión | Mauricio |

### Fase 1 · Proteger datos (código, prioridad alta)
| # | Tarea | Por qué | Decisión pendiente |
|---|---|---|---|
| ~~1.1~~ | ✅ **Hecho 2026-11-25.** Medidas atómicas (script 12) y "Siguiente"/"Finalizar" no avanzan si algo no se guardó. Una auditoría la llena una sola persona. | — | Confirmar en el uso diario |
| 1.1b | **Cantidades, defectos y pruebas** de auditorías siguen con `delete()` + `insert()` por separado. Ya no fallan en silencio ni dejan avanzar, pero si la red cae entre los dos y se cierra la página, esa parte se pierde. Pasar a funciones atómicas como la de medidas. | Pérdida parcial en un corte de red. | — |
| 1.2 | **Refresco automático de patronaje** con Supabase Realtime (como Diseño con `utilidades.js`): actualizar solo celdas que otro cambió, sin tocar lo que el usuario edita (§5.12). | Pantallas abiertas desde temprano no ven lo que otros guardan ("no guardó"). | — |
| 1.3 | **Retirar "📤 Importar Histórico"** de patronaje (ya no se usa, confirmado 2026-11-25): recarga toda la tabla y borra ediciones sin guardar. | Pérdida de ediciones al usarlo. | — |

### Fase 2 · Higiene (un solo paquete pequeño)
| # | Tarea |
|---|---|
| 2.1 | Fijar versión exacta de `@supabase/supabase-js` (hoy `@2` en 16 archivos, incluido el `+esm` de `sesion.js`). |
| 2.2 | Retirar la carpeta `public/` (versiones viejas con Firebase). |
| 2.3 | Depurar los **54 precintos repetidos** en `prendas` (5 con referencias distintas: MSTMUE11340, MSTMUE1758, MSTMUE9149, MSTMUE9267, MSTMUE9779). |

### Fase 3 · Rendimiento y seguridad
| # | Tarea |
|---|---|
| 3.1 | `formulario.html` guarda la foto en base64 dentro de `prendas.fotoUrl` (**345 fotos**, tabla de 11 MB): migrar a Storage y guardar solo la URL. |
| 3.2 | Bucket `dpto-tecnico` público → privado con `createSignedUrl`. |

### ✅ Resueltos
- 2026-11-25 · Auditorías: medidas en una sola transacción (script 12); "Siguiente"/"Finalizar" revisan el error
  de cada parte y no avanzan si algo falla; revision3 guarda color y número de prenda en sus columnas reales.
- 2026-11-25 · Botón "🔄 Actualizar desde Diseño" (script 11) y DISEÑADOR liberado del bloqueo.
- 2026-11-25 · Filtros de catálogo (GÉNERO, ESTADO, RESULTADO, TIPO) por igualdad: filtrar MEN ya no trae WOMEN.
  Importación usa `fechaServidor` para el más reciente.
- 2026-11-25 · Precinto y campos de Diseño bloqueados en patronaje (página + trigger, script 10).
  Retirado el botón "Migrar archivos".
- 2026-11-25 · Género unificado en `prendas`, `dpto_tecnico` y histórico (script 09). Los filtros
  "Solo Women/Men" de `reportes.html` ahora incluyen las ~1.760 prendas que estaban como FEMENINO/MASCULINO.
- 2026-11-24 · Historial de cambios de `dpto_tecnico` (script 08).
- 2026-11-24 · Texto perdido al escribir durante el autoguardado (§5.12).

### Cómo investigar un "lo guardé y desapareció"
1. Pedir hora, precinto y qué estaba haciendo la persona.
2. Mirar el valor actual en `dpto_tecnico` y su historia en `dpto_tecnico_cambios`
   (consultas de uso al final de `sql/08_historial_cambios_dpto.sql`).
3. Si el historial no muestra el cambio → nunca llegó a la base (problema en la pantalla o pestaña vieja).
   Si muestra que alguien lo vació → quién y cuándo.
4. Cruzar con los logs de la API (`edge_logs`) para ver si hubo errores 4xx/5xx a esa hora.

## 11. Forma de trabajar con el usuario

- Ir **paso a paso**: un paso, el usuario lo ejecuta y confirma, luego el siguiente.
- Entregar archivos **completos** listos para reemplazar (no fragmentos sueltos para pegar), indicando
  la carpeta exacta donde va cada uno.
- Antes de un cambio de datos, ofrecer una consulta de diagnóstico de solo lectura.
- Código con manejo de errores, logging con prefijo y comentarios que expliquen el porqué.
- Publicar en `main` solo con autorización explícita del usuario.
- **Cada vez que se modifique un `.html`, entregarle al usuario el archivo completo** (con su carpeta),
  idéntico a lo publicado en GitHub: él guarda en su escritorio la última versión de cada archivo.
- Ir **un paso a la vez**: no empezar el siguiente paso del plan hasta que el usuario confirme que el
  anterior quedó funcionando.
