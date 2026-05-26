-- ================================================================================================================================
--  ARCHIVO   : fertiliza_landing.sql
--  PROYECTO  : Sistema de Gestión de Inventario
--  MÓDULO    : Capa de Aterrizaje (Landing Zone)
--  BASE      : PostgreSQL
--  SCHEMA    : fertiliza_landing
--  VERSIÓN   : 1.0 - Mayo 2026
--
--  DESCRIPCIÓN:
--    Capa 0 del pipeline de datos. Recibe los archivos Excel exportados por EasyMorph
--    tal como vienen, sin transformaciones ni validaciones de tipo.
--
--    Filosofía de diseño:
--      • TODO es VARCHAR — ningún dato puede ser rechazado por tipo de dato.
--      • Sin FKs ni constraints de negocio — la limpieza ocurre en capas superiores.
--      • El ETL Python llena los flags de control (lnd_*) al momento de insertar.
--      • Este schema es de ESCRITURA rápida y LECTURA por el proceso ETL hacia
--        fertiliza_oltp.stg_*, nunca por la aplicación de negocio.
--
--    Flujo completo:
--      Excel/CSV
--        └─► Python ETL
--              └─► fertiliza_landing   (este schema — capa 0)
--                    └─► fertiliza_oltp.stg_*  (staging validado — capa 1)
--                          └─► fertiliza_oltp.*  (tablas operacionales — capa 2)
--
--  TABLAS:
--    1. lnd_carga             — Encabezado de cada ejecución de carga (1 por archivo)
--    2. lnd_fertilisa_raw     — Filas crudas de la hoja "Fertilisa"
--    3. lnd_manvert_jiffy_raw — Filas crudas de la hoja "Manvert, Jiffy"
--    4. lnd_archivo_log       — Log de archivos procesados (detección de duplicados)
--
--  ORDEN DE EJECUCIÓN:
--    1. Schema
--    2. Tabla de log de archivos
--    3. Tabla de encabezado de carga
--    4. Tablas de datos crudos
--    5. Índices operacionales
-- ================================================================================================================================


-- ================================================================================================================================
--  SECCIÓN 1: SCHEMA
-- ================================================================================================================================

CREATE SCHEMA IF NOT EXISTS fertiliza_landing;

SET search_path TO fertiliza_landing;


-- ================================================================================================================================
--  SECCIÓN 2: LOG DE ARCHIVOS
--  Registra cada archivo que ingresa al sistema. Permite detectar duplicados
--  antes de insertar una sola fila, comparando hash MD5 del archivo.
-- ================================================================================================================================

-- --------------------------------------------------------------------------------------------------------------------------------
--  2.1 LND_ARCHIVO_LOG — Registro de archivos recibidos
--  El ETL Python calcula el MD5 del archivo antes de procesarlo y consulta
--  esta tabla. Si el hash ya existe con estado 'Procesado', aborta la carga.
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lnd_archivo_log (
    id_archivo_log   SERIAL          PRIMARY KEY,

    -- Identificación del archivo
    nombre_archivo   VARCHAR(300)    NOT NULL,                       -- Nombre original: "Resumen.xlsx"
    ruta_origen      TEXT,                                           -- Ruta completa en disco o bucket S3/GCS
    hash_md5         VARCHAR(32)     NOT NULL,                       -- MD5 del binario del archivo
    tamanio_bytes    BIGINT,                                         -- Tamaño en bytes

    -- Metadatos de la carga
    hoja_excel       VARCHAR(100),                                   -- Nombre de la pestaña procesada (si es Excel)
    total_filas_raw  INT,                                            -- Total de filas leídas, incluyendo encabezados y vacías
    filas_insertadas INT,                                            -- Filas efectivamente insertadas en la tabla raw

    -- Estado del procesamiento
    estado           VARCHAR(20)     NOT NULL DEFAULT 'Recibido',    -- Recibido | En Proceso | Procesado | Duplicado | Error
    mensaje          TEXT,                                           -- Detalle si estado = 'Error' o 'Duplicado'

    -- Trazabilidad
    ejecutado_por    VARCHAR(100),                                   -- Usuario del sistema operativo o servicio que corrió el ETL
    script_version   VARCHAR(20),                                    -- Versión del script Python ETL (ej. "1.0.3")
    inicio_proceso   TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    fin_proceso      TIMESTAMPTZ                                     -- Se actualiza al finalizar
);

-- Índice para detección rápida de duplicados por hash
CREATE UNIQUE INDEX IF NOT EXISTS uidx_lnd_archivo_hash
    ON lnd_archivo_log (hash_md5)
    WHERE estado = 'Procesado';

CREATE INDEX IF NOT EXISTS idx_lnd_archivo_nombre
    ON lnd_archivo_log (nombre_archivo, inicio_proceso DESC);

COMMENT ON TABLE lnd_archivo_log IS
  'Registro de cada archivo recibido en la landing zone. '
  'El ETL Python debe consultar esta tabla antes de procesar para evitar cargas duplicadas. '
  'Si hash_md5 ya existe con estado Procesado, se debe abortar y registrar como Duplicado.';

COMMENT ON COLUMN lnd_archivo_log.hash_md5 IS
  'MD5 calculado sobre el binario del archivo. Usado como firma de deduplicación.';

COMMENT ON COLUMN lnd_archivo_log.script_version IS
  'Versión del script ETL Python. Útil para identificar si un error fue del script o del dato.';


-- ================================================================================================================================
--  SECCIÓN 3: ENCABEZADO DE CARGA
--  Una carga puede procesar una o más hojas del mismo archivo.
--  lnd_carga agrupa todas las inserciones de una misma ejecución del ETL.
-- ================================================================================================================================

-- --------------------------------------------------------------------------------------------------------------------------------
--  3.1 LND_CARGA — Encabezado de ejecución del ETL Python
--  Cada vez que el script Python corre, crea un registro aquí.
--  Todas las filas insertadas en las tablas raw referencian este id_carga.
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lnd_carga (
    id_carga         SERIAL          PRIMARY KEY,
    id_archivo_log   INT             NOT NULL REFERENCES lnd_archivo_log(id_archivo_log),

    -- Descripción de la carga
    descripcion      VARCHAR(300),                                   -- Texto libre: "Carga mensual mayo 2026"
    periodo_datos    VARCHAR(20),                                    -- Período al que corresponden los datos: "2026-05"
    hoja_procesada   VARCHAR(100),                                   -- Nombre de la hoja Excel procesada en esta carga

    -- Contadores (el ETL los actualiza al finalizar)
    filas_leidas     INT             DEFAULT 0,                      -- Filas totales leídas del archivo (con encabezado)
    filas_vacias     INT             DEFAULT 0,                      -- Filas ignoradas por estar completamente vacías
    filas_seccion    INT             DEFAULT 0,                      -- Filas identificadas como encabezado de sección (no datos)
    filas_insertadas INT             DEFAULT 0,                      -- Filas efectivamente insertadas en la tabla raw

    -- Estado
    estado           VARCHAR(20)     NOT NULL DEFAULT 'Iniciado',    -- Iniciado | Completado | Error
    mensaje_error    TEXT,

    -- Trazabilidad
    ejecutado_por    VARCHAR(100),
    inicio_carga     TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    fin_carga        TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_lnd_carga_archivo
    ON lnd_carga (id_archivo_log);

CREATE INDEX IF NOT EXISTS idx_lnd_carga_periodo
    ON lnd_carga (periodo_datos);

COMMENT ON TABLE lnd_carga IS
  'Encabezado de cada ejecución del ETL Python. Agrupa todas las filas raw insertadas en esa corrida. '
  'Permite saber exactamente cuántas filas llegaron, cuántas eran vacías y cuántas se insertaron.';

COMMENT ON COLUMN lnd_carga.filas_seccion IS
  'Filas que el ETL identificó como encabezado de sección (ej. "Granular - Solubles"). '
  'Estas filas no se insertan como datos sino que se usan para el fill-down de categoría.';


-- ================================================================================================================================
--  SECCIÓN 4: TABLAS DE DATOS CRUDOS
--  Una tabla por cada hoja del Excel. 
--  Reglas de oro:
--    - TODOS los campos de dato son VARCHAR. Sin excepción.
--    - Sin CHECK constraints sobre los valores de dato.
--    - Sin FKs hacia tablas de negocio.
--    - Solo los campos de control (lnd_*) tienen tipos nativos.
-- ================================================================================================================================

-- --------------------------------------------------------------------------------------------------------------------------------
--  4.1 LND_FERTILISA_RAW — Hoja "Fertilisa" del archivo Resumen.xlsx
--
--  Estructura de la hoja fuente (columnas conocidas):
--    Col A : (vacía o número de fila interno)
--    Col B : Código del producto  → puede venir como '4000100372 (con apóstrofe)
--    Col C : Nombre del producto
--    Col D : Stock físico contado
--    Col E : Saldo según Sistema David
--    Col F : Diferencia (física - sistema)
--    Col G : Observaciones
--
--  Filas especiales que el ETL debe manejar:
--    - Filas de sección: contienen solo el nombre de la categoría en Col C
--      (ej. "Granular - Solubles"). Se usan para fill-down del campo categoria_raw.
--    - Filas totalmente vacías: se descartan sin insertar.
--    - Fila de encabezado: se descarta (fila 1 del Excel).
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lnd_fertilisa_raw (
    id_lnd_fert      SERIAL          PRIMARY KEY,
    id_carga         INT             NOT NULL REFERENCES lnd_carga(id_carga),

    -- ── Datos tal como vienen del Excel ─────────────────────────────────────────
    col_a_raw        VARCHAR(100),                                   -- Columna A (generalmente vacía o índice)
    codigo_raw       VARCHAR(100),                                   -- Col B: código, puede tener apóstrofe líder
    nombre_raw       VARCHAR(500),                                   -- Col C: nombre del producto o nombre de sección
    fisico_raw       VARCHAR(50),                                    -- Col D: cantidad física (puede venir como "1,234.56" o texto)
    sistema_raw      VARCHAR(50),                                    -- Col E: saldo sistema David
    diferencia_raw   VARCHAR(50),                                    -- Col F: diferencia (puede tener "-", "(123)", texto)
    observacion_raw  VARCHAR(1000),                                  -- Col G: observación de texto libre

    -- ── Campos derivados por el ETL Python en el momento de la carga ────────────
    categoria_raw    VARCHAR(200),                                   -- Resultado del fill-down de filas de sección
    fila_excel       INT,                                            -- Número de fila en el archivo Excel (base 1)
    es_fila_seccion  BOOLEAN         NOT NULL DEFAULT FALSE,         -- TRUE si esta fila es un encabezado de sección
    es_fila_vacia    BOOLEAN         NOT NULL DEFAULT FALSE,         -- TRUE si todos los campos de dato estaban vacíos

    -- ── Flags de calidad llenados por el ETL ────────────────────────────────────
    -- El ETL Python hace una revisión rápida (no exhaustiva) al insertar.
    -- La validación profunda ocurre en fertiliza_oltp.stg_*.
    lnd_tiene_codigo     BOOLEAN,                                    -- TRUE si codigo_raw no es NULL ni vacío tras limpiar apóstrofe
    lnd_tiene_nombre     BOOLEAN,                                    -- TRUE si nombre_raw no es NULL ni vacío
    lnd_fisico_numerico  BOOLEAN,                                    -- TRUE si fisico_raw parsea como número
    lnd_sistema_numerico BOOLEAN,                                    -- TRUE si sistema_raw parsea como número
    lnd_listo_para_stg   BOOLEAN     NOT NULL DEFAULT FALSE,         -- TRUE = esta fila puede pasar al staging del OLTP

    -- ── Trazabilidad ────────────────────────────────────────────────────────────
    creado_en        TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

-- Índices operacionales
CREATE INDEX IF NOT EXISTS idx_lnd_fert_carga
    ON lnd_fertilisa_raw (id_carga);

CREATE INDEX IF NOT EXISTS idx_lnd_fert_listo
    ON lnd_fertilisa_raw (id_carga, lnd_listo_para_stg)
    WHERE lnd_listo_para_stg = TRUE;

CREATE INDEX IF NOT EXISTS idx_lnd_fert_codigo
    ON lnd_fertilisa_raw (codigo_raw)
    WHERE codigo_raw IS NOT NULL;

COMMENT ON TABLE lnd_fertilisa_raw IS
  'Landing zone para la hoja "Fertilisa" del archivo Resumen.xlsx. '
  'Recibe las filas exactamente como vienen del Excel, incluyendo filas de sección '
  'y filas vacías (marcadas con flags). El ETL Python llena los campos lnd_* '
  'como resultado de una revisión superficial de calidad.';

COMMENT ON COLUMN lnd_fertilisa_raw.categoria_raw IS
  'Categoría asignada por fill-down: el ETL Python lee las filas de sección '
  '(es_fila_seccion = TRUE) y propaga ese valor hacia abajo hasta la siguiente sección.';

COMMENT ON COLUMN lnd_fertilisa_raw.lnd_listo_para_stg IS
  'Flag de paso. El proceso ETL que lee este landing y escribe en fertiliza_oltp.stg_* '
  'debe filtrar WHERE lnd_listo_para_stg = TRUE para tomar solo filas procesables.';


-- --------------------------------------------------------------------------------------------------------------------------------
--  4.2 LND_MANVERT_JIFFY_RAW — Hoja "Manvert, Jiffy" del archivo Resumen.xlsx
--
--  Esta hoja tiene columnas adicionales respecto a la hoja Fertilisa:
--    Col A : Número de lote
--    Col B : Código del producto
--    Col C : Nombre del material
--    Col D : Estado del lote (código numérico: 569, 905, 1239…)
--    Col E : Stock físico
--    Col F : Saldo sistema David
--    Col G : Diferencia
--    Col H : Observaciones
--    Col I : Fecha de vencimiento (puede venir como fecha Excel serial, texto, ISO)
--    Col J : Días de almacenaje permitidos
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lnd_manvert_jiffy_raw (
    id_lnd_mj        SERIAL          PRIMARY KEY,
    id_carga         INT             NOT NULL REFERENCES lnd_carga(id_carga),

    -- ── Datos tal como vienen del Excel ─────────────────────────────────────────
    lote_raw         VARCHAR(100),                                   -- Col A: número de lote (1483, 1358…)
    codigo_raw       VARCHAR(100),                                   -- Col B: código del producto
    nombre_raw       VARCHAR(500),                                   -- Col C: nombre del material
    estado_lote_raw  VARCHAR(50),                                    -- Col D: código de estado del lote
    fisico_raw       VARCHAR(50),                                    -- Col E: cantidad física
    sistema_raw      VARCHAR(50),                                    -- Col F: saldo sistema David
    diferencia_raw   VARCHAR(50),                                    -- Col G: diferencia
    observacion_raw  VARCHAR(1000),                                  -- Col H: observación
    fecha_venc_raw   VARCHAR(100),                                   -- Col I: fecha de vencimiento en cualquier formato
    almacenaje_raw   VARCHAR(50),                                    -- Col J: días de almacenaje

    -- ── Campos derivados por el ETL Python ──────────────────────────────────────
    fila_excel       INT,                                            -- Número de fila en el archivo Excel
    es_fila_seccion  BOOLEAN         NOT NULL DEFAULT FALSE,
    es_fila_vacia    BOOLEAN         NOT NULL DEFAULT FALSE,

    -- ── Flags de calidad ────────────────────────────────────────────────────────
    lnd_tiene_codigo        BOOLEAN,
    lnd_tiene_nombre        BOOLEAN,
    lnd_fisico_numerico     BOOLEAN,
    lnd_sistema_numerico    BOOLEAN,
    lnd_fecha_venc_parseable BOOLEAN,                               -- TRUE si fecha_venc_raw pudo convertirse a fecha válida
    lnd_almacenaje_numerico BOOLEAN,                                -- TRUE si almacenaje_raw es un entero válido
    lnd_listo_para_stg      BOOLEAN    NOT NULL DEFAULT FALSE,

    -- ── Trazabilidad ────────────────────────────────────────────────────────────
    creado_en        TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_lnd_mj_carga
    ON lnd_manvert_jiffy_raw (id_carga);

CREATE INDEX IF NOT EXISTS idx_lnd_mj_listo
    ON lnd_manvert_jiffy_raw (id_carga, lnd_listo_para_stg)
    WHERE lnd_listo_para_stg = TRUE;

CREATE INDEX IF NOT EXISTS idx_lnd_mj_codigo
    ON lnd_manvert_jiffy_raw (codigo_raw)
    WHERE codigo_raw IS NOT NULL;

COMMENT ON TABLE lnd_manvert_jiffy_raw IS
  'Landing zone para la hoja "Manvert, Jiffy" del archivo Resumen.xlsx. '
  'Incluye los campos de lote, estado de lote, fecha de vencimiento y días de almacenaje '
  'que son propios de esta hoja y no existen en lnd_fertilisa_raw.';

COMMENT ON COLUMN lnd_manvert_jiffy_raw.fecha_venc_raw IS
  'La fecha de vencimiento puede venir como número serial de Excel (ej. 45678), '
  'como texto ISO (2026-08-15), o como fecha local (15/08/2026). '
  'El ETL Python debe intentar parsearla y registrar el resultado en lnd_fecha_venc_parseable.';


-- ================================================================================================================================
--  SECCIÓN 5: VISTA DE APOYO PARA EL ETL
--  Una vista que expone solo las filas listas para pasar al OLTP,
--  con los campos mínimos necesarios para el staging del OLTP.
--  El ETL Python puede leer de aquí en lugar de escribir la lógica de filtro.
-- ================================================================================================================================

-- --------------------------------------------------------------------------------------------------------------------------------
--  5.1 v_fertilisa_para_stg — Filas de la hoja Fertilisa listas para el OLTP
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_fertilisa_para_stg AS
SELECT
    f.id_lnd_fert,
    f.id_carga,
    c.periodo_datos,
    -- Limpieza básica del código (remover apóstrofe líder si existe)
    TRIM(LEADING '''' FROM COALESCE(f.codigo_raw, ''))      AS codigo_limpio,
    TRIM(f.nombre_raw)                                       AS nombre_limpio,
    TRIM(f.fisico_raw)                                       AS fisico_raw,
    TRIM(f.sistema_raw)                                      AS sistema_raw,
    TRIM(f.diferencia_raw)                                   AS diferencia_raw,
    TRIM(f.observacion_raw)                                  AS observacion_raw,
    f.categoria_raw,
    f.fila_excel
FROM  lnd_fertilisa_raw f
JOIN  lnd_carga          c ON c.id_carga = f.id_carga
WHERE f.lnd_listo_para_stg = TRUE
  AND f.es_fila_seccion    = FALSE
  AND f.es_fila_vacia      = FALSE;

COMMENT ON VIEW v_fertilisa_para_stg IS
  'Filas de lnd_fertilisa_raw listas para ser insertadas en fertiliza_oltp.stg_inventario_raw. '
  'Aplica limpieza superficial (trim, remoción de apóstrofe). '
  'El ETL Python puede hacer INSERT INTO fertiliza_oltp.stg_inventario_raw SELECT ... FROM esta vista.';


-- --------------------------------------------------------------------------------------------------------------------------------
--  5.2 v_manvert_jiffy_para_stg — Filas de la hoja Manvert/Jiffy listas para el OLTP
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_manvert_jiffy_para_stg AS
SELECT
    m.id_lnd_mj,
    m.id_carga,
    c.periodo_datos,
    TRIM(LEADING '''' FROM COALESCE(m.lote_raw, ''))        AS lote_limpio,
    TRIM(LEADING '''' FROM COALESCE(m.codigo_raw, ''))      AS codigo_limpio,
    TRIM(m.nombre_raw)                                       AS nombre_limpio,
    TRIM(m.estado_lote_raw)                                  AS estado_lote_raw,
    TRIM(m.fisico_raw)                                       AS fisico_raw,
    TRIM(m.sistema_raw)                                      AS sistema_raw,
    TRIM(m.diferencia_raw)                                   AS diferencia_raw,
    TRIM(m.observacion_raw)                                  AS observacion_raw,
    TRIM(m.fecha_venc_raw)                                   AS fecha_venc_raw,
    TRIM(m.almacenaje_raw)                                   AS almacenaje_raw,
    m.fila_excel,
    m.lnd_fecha_venc_parseable
FROM  lnd_manvert_jiffy_raw m
JOIN  lnd_carga              c ON c.id_carga = m.id_carga
WHERE m.lnd_listo_para_stg = TRUE
  AND m.es_fila_seccion    = FALSE
  AND m.es_fila_vacia      = FALSE;

COMMENT ON VIEW v_manvert_jiffy_para_stg IS
  'Filas de lnd_manvert_jiffy_raw listas para ser insertadas en fertiliza_oltp.stg_manvert_jiffy_raw. '
  'Aplica limpieza superficial equivalente a la vista v_fertilisa_para_stg.';


-- ================================================================================================================================
--  SECCIÓN 6: RESUMEN PARA EL ETL PYTHON
--  Vista operativa que el script puede consultar para saber el estado
--  de cada carga sin tener que hacer JOINs manuales.
-- ================================================================================================================================

CREATE OR REPLACE VIEW v_resumen_cargas AS
SELECT
    c.id_carga,
    a.nombre_archivo,
    a.hash_md5,
    c.periodo_datos,
    c.hoja_procesada,
    c.filas_leidas,
    c.filas_vacias,
    c.filas_seccion,
    c.filas_insertadas,
    -- Contadores en tiempo real desde las tablas raw
    (SELECT COUNT(*) FROM lnd_fertilisa_raw     f WHERE f.id_carga = c.id_carga AND f.lnd_listo_para_stg = TRUE) AS fert_listas,
    (SELECT COUNT(*) FROM lnd_fertilisa_raw     f WHERE f.id_carga = c.id_carga AND f.lnd_listo_para_stg = FALSE
                                                    AND f.es_fila_seccion = FALSE AND f.es_fila_vacia = FALSE)    AS fert_con_problemas,
    (SELECT COUNT(*) FROM lnd_manvert_jiffy_raw m WHERE m.id_carga = c.id_carga AND m.lnd_listo_para_stg = TRUE) AS mj_listas,
    (SELECT COUNT(*) FROM lnd_manvert_jiffy_raw m WHERE m.id_carga = c.id_carga AND m.lnd_listo_para_stg = FALSE
                                                    AND m.es_fila_seccion = FALSE AND m.es_fila_vacia = FALSE)    AS mj_con_problemas,
    c.estado,
    c.inicio_carga,
    c.fin_carga
FROM  lnd_carga         c
JOIN  lnd_archivo_log   a ON a.id_archivo_log = c.id_archivo_log
ORDER BY c.inicio_carga DESC;

COMMENT ON VIEW v_resumen_cargas IS
  'Vista operativa para monitorear el estado de cada carga. '
  'Muestra cuántas filas están listas para pasar al OLTP y cuántas tienen problemas de calidad.';
