-- ================================================================================================================================
--  ARCHIVO   : fertiliza_dwh.sql
--  PROYECTO  : Sistema de Gestión de Inventario
--  MÓDULO    : Data Warehouse — Modelo Dimensional (Esquema Estrella)
--  BASE      : PostgreSQL 
--  SCHEMA    : fertiliza_dw
--  VERSIÓN   : 1.0 — Mayo 2026
--
--  DESCRIPCIÓN:
--    Implementa el modelo dimensional orientado al análisis (OLAP) basado en
--    el esquema estrella. Extrae y transforma los datos del modelo operacional
--    (fertilisa_oltp) a través del proceso ETL definido en 03_etl_transformaciones.sql.
--
--    El modelo contiene:
--      • 6 dimensiones:  DIM_TIEMPO, DIM_PRODUCTO (SCD2), DIM_CATEGORIA,
--                        DIM_MARCA, DIM_ESTADO_STOCK, DIM_TIPO_DISCREPANCIA
--      • 2 hechos:       FACT_INVENTARIO, FACT_DISCREPANCIA
--      • Tablas de control ETL: etl_control_carga, etl_control_dimension
--      • Tabla de auditoría del DWH: dw_audit_log
--      • Vistas analíticas pre-construidas para los KPIs principales
--
--  ORDEN DE EJECUCIÓN:
--    1. Schema y configuración
--    2. Tabla de auditoría del DWH
--    3. Tablas de control ETL
--    4. Dimensiones (DIM_*)
--    5. Tablas de hechos (FACT_*)
--    6. Índices analíticos
--    7. Vistas de KPIs
--    8. Consultas analíticas para preguntas de negocio
-- ================================================================================================================================


-- ================================================================================================================================
--  SECCIÓN 1: SCHEMA Y CONFIGURACIÓN
-- ================================================================================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Schema aislado para el Data Warehouse; evita conflictos con el OLTP
CREATE SCHEMA IF NOT EXISTS fertiliza_dwh;

SET search_path TO fertiliza_dwh;


-- ================================================================================================================================
--  SECCIÓN 2: AUDITORÍA DEL DATA WAREHOUSE
--  Registra cada ejecución del ETL y los cambios en el modelo dimensional.
-- ================================================================================================================================

-- --------------------------------------------------------------------------------------------------------------------------------
--  2.1 DW_AUDIT_LOG — Bitácora de eventos dentro del DWH
--  A diferencia del audit_log del OLTP (que audita filas individuales),
--  este log audita procesos: cargas ETL, actualizaciones SCD, ejecuciones de queries.
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dw_audit_log (
    id_evento        UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
    proceso          VARCHAR(100) NOT NULL,                                  -- Nombre del proceso (ETL, SCD2, Validación…)
    tabla_afectada   VARCHAR(100),                                           -- Dimensión o hecho modificado
    operacion        VARCHAR(30)  NOT NULL,                                  -- 'CARGA_INICIAL','SCD2_CIERRE','SCD2_INSERT','DELETE','TRUNCATE'
    filas_insertadas INT          NOT NULL DEFAULT 0,
    filas_actualizadas INT        NOT NULL DEFAULT 0,
    filas_eliminadas INT          NOT NULL DEFAULT 0,
    filas_rechazadas INT          NOT NULL DEFAULT 0,
    inicio_proceso   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    fin_proceso      TIMESTAMPTZ,                                            -- Se rellena al terminar el proceso
    duracion_seg     NUMERIC(10,3) GENERATED ALWAYS AS
                     (EXTRACT(EPOCH FROM (fin_proceso - inicio_proceso))) STORED,
    estado           VARCHAR(15)  NOT NULL DEFAULT 'En Proceso'
                     CHECK (estado IN ('En Proceso','Completado','Error','Advertencia')),
    mensaje          TEXT,                                                   -- Detalle del resultado o del error
    usuario_db       VARCHAR(100) NOT NULL DEFAULT current_user,
    id_carga_origen  INT                                                     -- FK al id_carga del stg_carga en OLTP (trazabilidad extremo a extremo)
);

CREATE INDEX IF NOT EXISTS idx_dw_audit_proceso ON dw_audit_log (proceso, inicio_proceso DESC);
CREATE INDEX IF NOT EXISTS idx_dw_audit_tabla   ON dw_audit_log (tabla_afectada, inicio_proceso DESC);

COMMENT ON TABLE dw_audit_log IS
  'Bitácora de procesos ETL y operaciones de mantenimiento del Data Warehouse. '
  'Permite rastrear cuándo se cargó cada dimensión o tabla de hechos y cuántas filas se procesaron.';


-- ================================================================================================================================
--  SECCIÓN 3: TABLAS DE CONTROL ETL
--  Permiten gestionar la carga incremental y el estado de cada dimensión.
-- ================================================================================================================================

-- --------------------------------------------------------------------------------------------------------------------------------
--  3.1 ETL_CONTROL_CARGA — Marca de agua (watermark) de la última carga exitosa
--  El ETL consulta esta tabla para saber desde qué punto debe extraer
--  datos del modelo operacional (carga incremental).
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS etl_control_carga (
    id_control       SERIAL       PRIMARY KEY,
    nombre_proceso   VARCHAR(100) NOT NULL UNIQUE,                           -- Identificador único del proceso ETL
    ultima_carga_ok  TIMESTAMPTZ,                                            -- Timestamp de la última carga completada sin error
    ultima_fecha_dato DATE,                                                  -- Fecha del dato más reciente cargado (ej. fecha de toma física)
    total_cargas     INT          NOT NULL DEFAULT 0,                        -- Contador acumulado de ejecuciones exitosas
    estado_ultimo    VARCHAR(15)  NOT NULL DEFAULT 'Nunca Ejecutado'
                     CHECK (estado_ultimo IN ('Completado','Error','En Proceso','Nunca Ejecutado')),
    mensaje_ultimo   TEXT,
    modificado_en    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Registrar los procesos ETL del proyecto desde el inicio
INSERT INTO etl_control_carga (nombre_proceso, estado_ultimo) VALUES
    ('ETL_DIM_TIEMPO',             'Nunca Ejecutado'),
    ('ETL_DIM_MARCA',              'Nunca Ejecutado'),
    ('ETL_DIM_CATEGORIA',          'Nunca Ejecutado'),
    ('ETL_DIM_PRODUCTO',           'Nunca Ejecutado'),
    ('ETL_DIM_ESTADO_STOCK',       'Nunca Ejecutado'),
    ('ETL_DIM_TIPO_DISCREPANCIA',  'Nunca Ejecutado'),
    ('ETL_FACT_INVENTARIO',        'Nunca Ejecutado'),
    ('ETL_FACT_DISCREPANCIA',      'Nunca Ejecutado')
ON CONFLICT (nombre_proceso) DO NOTHING;

COMMENT ON TABLE etl_control_carga IS
  'Marca de agua de la última ejecución exitosa de cada proceso ETL. '
  'Permite implementar cargas incrementales: el ETL solo procesa datos nuevos desde ultima_carga_ok.';


-- --------------------------------------------------------------------------------------------------------------------------------
--  3.2 ETL_CONTROL_DIMENSION — Registro de versiones de dimensiones (para SCD2)
--  Lleva la cuenta de cuántas versiones activas e históricas existen
--  en DIM_PRODUCTO y otras dimensiones con SCD2.
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS etl_control_dimension (
    id_control_dim   SERIAL       PRIMARY KEY,
    nombre_dimension VARCHAR(60)  NOT NULL,                                  -- 'DIM_PRODUCTO', 'DIM_CATEGORIA'…
    total_registros  INT          NOT NULL DEFAULT 0,                        -- Total de filas incluyendo históricas
    registros_activos INT         NOT NULL DEFAULT 0,                        -- Solo versiones con es_registro_activo = TRUE
    registros_hist   INT          NOT NULL DEFAULT 0,                        -- Versiones históricas (SCD2 cerradas)
    ultima_revision  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE etl_control_dimension IS
  'Estadísticas de cada dimensión: total de registros, activos e históricos (SCD2). '
  'El ETL actualiza esta tabla al finalizar cada carga de dimensión.';


-- ================================================================================================================================
--  SECCIÓN 4: DIMENSIONES DEL MODELO ESTRELLA
-- ================================================================================================================================

-- --------------------------------------------------------------------------------------------------------------------------------
--  4.1 DIM_TIEMPO — Dimensión de tiempo obligatoria
--
--  Llave subrogada: entero en formato YYYYMMDD (ej. 20260525).
--  Este formato permite filtros de rango eficientes con BETWEEN
--  y es autoexplicativo sin necesidad de JOIN con la dimensión.
--
--  Jerarquía: Año -> Trimestre -> Mes -> Semana ISO -> Día
--
--  Se pre-puebla con todos los días del período 2020-01-01 a 2030-12-31
--  (incluye también una fila "desconocida" con sk = -1 para manejar
--  fechas nulas en las tablas de hechos sin violar la integridad referencial).
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_tiempo (
    sk_tiempo        INT          PRIMARY KEY,           -- YYYYMMDD; -1 = fecha desconocida
    fecha_completa   DATE         NOT NULL,
    anio             SMALLINT     NOT NULL,              -- Nivel 1 de la jerarquía
    nombre_anio      CHAR(4)      NOT NULL,              -- '2026', '2027'… (útil en etiquetas de gráficos)
    trimestre        SMALLINT     NOT NULL               -- Nivel 2 de la jerarquía
                     CHECK (trimestre BETWEEN 1 AND 4),
    nombre_trimestre VARCHAR(8)   NOT NULL,              -- 'Q1-2026', 'Q2-2026'…
    mes              SMALLINT     NOT NULL               -- Nivel 3
                     CHECK (mes BETWEEN 1 AND 12),
    nombre_mes       VARCHAR(20)  NOT NULL,              -- 'Enero', 'Febrero'…
    anio_mes         VARCHAR(8)   NOT NULL,              -- '2026-05' (para ordenamiento cronológico en gráficos)
    semana_anio      SMALLINT     NOT NULL,              -- Semana ISO 1-53 (nivel 4)
    nombre_semana    VARCHAR(12)  NOT NULL,              -- 'S01-2026'…
    dia_mes          SMALLINT     NOT NULL               -- Día del mes 1-31
                     CHECK (dia_mes BETWEEN 1 AND 31),
    dia_semana       SMALLINT     NOT NULL               -- ISO: 1=Lunes … 7=Domingo
                     CHECK (dia_semana BETWEEN 1 AND 7),
    nombre_dia       VARCHAR(15)  NOT NULL,              -- 'Lunes', 'Martes'…
    es_fin_semana    BOOLEAN      NOT NULL DEFAULT FALSE,
    es_feriado    BOOLEAN      NOT NULL DEFAULT FALSE,-- Feriados oficiales de Costa Rica
    nombre_feriado   VARCHAR(60)                         -- Nombre del feriado si aplica
);

-- Índice sobre la fecha para búsquedas por rango que no usen la SK directamente
CREATE INDEX IF NOT EXISTS idx_dim_tiempo_fecha ON dim_tiempo (fecha_completa);
CREATE INDEX IF NOT EXISTS idx_dim_tiempo_anio  ON dim_tiempo (anio, mes);

COMMENT ON TABLE dim_tiempo IS
  'Dimensión de tiempo. Contiene un registro por día para el período 2020-2030. '
  'Llave subrogada en formato YYYYMMDD para facilitar filtros de rango eficientes.';
COMMENT ON COLUMN dim_tiempo.sk_tiempo IS
  'Llave subrogada formato YYYYMMDD. El valor -1 representa fecha desconocida (sustituto de NULL).';

-- Fila especial "fecha desconocida" para mantener integridad referencial cuando la fecha es NULL
INSERT INTO dim_tiempo
    (sk_tiempo, fecha_completa, anio, nombre_anio, trimestre, nombre_trimestre,
     mes, nombre_mes, anio_mes, semana_anio, nombre_semana,
     dia_mes, dia_semana, nombre_dia, es_fin_semana, es_feriado)
VALUES
    (-1, '1900-01-01', 0, 'N/A', 0, 'N/A', 0, 'Desconocido', 'N/A',
     0, 'N/A', 0, 0, 'Desconocido', FALSE, FALSE)
ON CONFLICT (sk_tiempo) DO NOTHING;

-- Poblar la dimensión con todos los días del período de análisis
INSERT INTO dim_tiempo (
    sk_tiempo, fecha_completa,
    anio, nombre_anio,
    trimestre, nombre_trimestre,
    mes, nombre_mes, anio_mes,
    semana_anio, nombre_semana,
    dia_mes, dia_semana, nombre_dia,
    es_fin_semana, es_feriado, nombre_feriado
)
SELECT
    -- Llave subrogada: concatenar año, mes y día como entero (20260525)
    TO_CHAR(d, 'YYYYMMDD')::INT,
    d,
    EXTRACT(YEAR    FROM d)::SMALLINT,
    TO_CHAR(d, 'YYYY'),
    EXTRACT(QUARTER FROM d)::SMALLINT,
    -- Nombre de trimestre: Q1-2026, Q2-2026…
    'Q' || EXTRACT(QUARTER FROM d)::TEXT || '-' || TO_CHAR(d, 'YYYY'),
    EXTRACT(MONTH   FROM d)::SMALLINT,
    -- Mes en español (conversión manual independiente del locale del servidor)
    CASE EXTRACT(MONTH FROM d)::INT
        WHEN 1  THEN 'Enero'     WHEN 2  THEN 'Febrero'
        WHEN 3  THEN 'Marzo'     WHEN 4  THEN 'Abril'
        WHEN 5  THEN 'Mayo'      WHEN 6  THEN 'Junio'
        WHEN 7  THEN 'Julio'     WHEN 8  THEN 'Agosto'
        WHEN 9  THEN 'Septiembre' WHEN 10 THEN 'Octubre'
        WHEN 11 THEN 'Noviembre' WHEN 12 THEN 'Diciembre'
    END,
    TO_CHAR(d, 'YYYY-MM'),                              -- '2026-05' para ordenamiento cronológico
    EXTRACT(WEEK    FROM d)::SMALLINT,
    'S' || LPAD(EXTRACT(WEEK FROM d)::TEXT, 2, '0') || '-' || TO_CHAR(d, 'YYYY'),
    EXTRACT(DAY     FROM d)::SMALLINT,
    EXTRACT(ISODOW  FROM d)::SMALLINT,
    -- Día de la semana en español
    CASE EXTRACT(ISODOW FROM d)::INT
        WHEN 1 THEN 'Lunes'     WHEN 2 THEN 'Martes'
        WHEN 3 THEN 'Miércoles' WHEN 4 THEN 'Jueves'
        WHEN 5 THEN 'Viernes'   WHEN 6 THEN 'Sábado'
        WHEN 7 THEN 'Domingo'
    END,
    -- Fin de semana: ISO 6=Sábado, 7=Domingo
    EXTRACT(ISODOW FROM d) IN (6, 7),
    -- Feriados nacionales de Costa Rica (lista de fechas MM-DD)
    TO_CHAR(d, 'MM-DD') IN (
        '01-01',  -- Año Nuevo
        '04-11',  -- Día de Juan Santamaría
        '05-01',  -- Día del Trabajo
        '07-25',  -- Anexión del Partido de Nicoya
        '08-02',  -- Virgen de los Ángeles (peregrinación)
        '08-15',  -- Día de la Madre
        '09-15',  -- Día de la Independencia
        '10-12',  -- Día de las Culturas
        '12-25'   -- Navidad
    ),
    -- Nombre del feriado (NULL si no aplica)
    CASE TO_CHAR(d, 'MM-DD')
        WHEN '01-01' THEN 'Año Nuevo'
        WHEN '04-11' THEN 'Día de Juan Santamaría'
        WHEN '05-01' THEN 'Día del Trabajo'
        WHEN '07-25' THEN 'Anexión del Partido de Nicoya'
        WHEN '08-02' THEN 'Virgen de los Ángeles'
        WHEN '08-15' THEN 'Día de la Madre'
        WHEN '09-15' THEN 'Día de la Independencia'
        WHEN '10-12' THEN 'Día de las Culturas'
        WHEN '12-25' THEN 'Navidad'
        ELSE NULL
    END
FROM generate_series('2020-01-01'::DATE, '2030-12-31'::DATE, '1 day'::INTERVAL) AS d
ON CONFLICT (sk_tiempo) DO NOTHING;


-- --------------------------------------------------------------------------------------------------------------------------------
--  4.2 DIM_MARCA — Dimensión conformada de marcas / proveedores
--
--  "Conformada" significa que es compartida por ambas tablas de hechos
--  (FACT_INVENTARIO y FACT_DISCREPANCIA) sin redefinirla.
--  Esto garantiza que los análisis por marca sean consistentes entre hechos.
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_marca (
    sk_marca         SERIAL       PRIMARY KEY,           -- Llave subrogada auto-incremental
    nk_marca         VARCHAR(80)  NOT NULL UNIQUE,       -- Llave natural = nombre canónico de la marca
    nombre_marca     VARCHAR(80)  NOT NULL,
    pais_origen      VARCHAR(50)  NOT NULL DEFAULT 'Desconocido',
    tipo_proveedor   VARCHAR(15)  NOT NULL DEFAULT 'Desconocido'
                     CHECK (tipo_proveedor IN ('Nacional','Importado','Desconocido')),
    -- Fila especial para casos sin marca identificada
    es_sin_definir   BOOLEAN      NOT NULL DEFAULT FALSE
);

-- Fila "Sin Definir" para manejar casos sin marca sin romper la integridad referencial
INSERT INTO dim_marca (nk_marca, nombre_marca, pais_origen, tipo_proveedor, es_sin_definir)
VALUES ('SIN_MARCA', 'Sin Marca Definida', 'Desconocido', 'Desconocido', TRUE)
ON CONFLICT (nk_marca) DO NOTHING;

INSERT INTO dim_marca (nk_marca, nombre_marca, pais_origen, tipo_proveedor) VALUES
    ('Fertilisa',         'Fertilisa',         'Costa Rica',     'Nacional'),
    ('Manvert',           'Manvert',           'España',         'Importado'),
    ('Jiffy',             'Jiffy',             'Noruega',        'Importado'),
    ('ABP',               'ABP',               'Costa Rica',     'Nacional'),
    ('BioControl',        'BioControl',        'Costa Rica',     'Nacional'),
    ('Opistra',           'Opistra',           'Costa Rica',     'Nacional'),
    ('Manttra',           'Manttra',           'Costa Rica',     'Nacional'),
    ('YaraBela',          'YaraBela',          'Noruega',        'Importado'),
    ('Brandt',            'Brandt',            'Estados Unidos', 'Importado'),
    ('QTS',               'QTS',               'Desconocido',    'Desconocido'),
    ('GranuPotasse',      'GranuPotasse',      'Francia',        'Importado'),
    ('DAP',               'DAP',               'Desconocido',    'Importado'),
    ('Material Agrícola', 'Material Agrícola', 'Desconocido',    'Desconocido'),
    ('Poema',             'Poema',             'Desconocido',    'Desconocido'),
    ('Agrotecnica',       'Agrotecnica',       'Costa Rica',     'Nacional'),
    ('Otros',             'Otros',             'Desconocido',    'Desconocido')
ON CONFLICT (nk_marca) DO NOTHING;

COMMENT ON TABLE dim_marca IS
  'Dimensión conformada de marcas/proveedores. '
  'Compartida por FACT_INVENTARIO y FACT_DISCREPANCIA para asegurar consistencia en los análisis.';


-- --------------------------------------------------------------------------------------------------------------------------------
--  4.3 DIM_CATEGORIA — Dimensión conformada de categorías de inventario
--
--  También conformada: usada en ambas tablas de hechos.
--  Contiene la jerarquía implícita: Tipo de Producto → Categoría.
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_categoria (
    sk_categoria     SERIAL       PRIMARY KEY,
    nk_categoria     VARCHAR(15)  NOT NULL UNIQUE,       -- Código corto (GS, LQ, MI)
    nombre_categoria VARCHAR(120) NOT NULL UNIQUE,       -- Nombre completo tal como aparece en el Excel
    tipo_producto    VARCHAR(30)  NOT NULL               -- Nivel superior de la jerarquía
                     CHECK (tipo_producto IN ('Granular','Líquido','Sustrato-Material','Desconocido')),
    descripcion      VARCHAR(400),
    es_sin_definir   BOOLEAN      NOT NULL DEFAULT FALSE
);

-- Fila de valor desconocido
INSERT INTO dim_categoria (nk_categoria, nombre_categoria, tipo_producto, es_sin_definir)
VALUES ('ND', 'Sin Categoría', 'Desconocido', TRUE)
ON CONFLICT (nk_categoria) DO NOTHING;

INSERT INTO dim_categoria (nk_categoria, nombre_categoria, tipo_producto, descripcion) VALUES
    ('GS',  'Granular - Solubles',
             'Granular',
             'Fertilizantes granulares y solubles. Incluye Fertilisa, ABP, Bio, Opistra, Manttra, YaraBela, Brandt, DAP.'),
    ('LQ',  'Liquidos',
             'Líquido',
             'Fertilizantes y bioestimulantes líquidos. Incluye Manvert, ABP Líquidos, Agrotecnica.'),
    ('MI',  'Material para Invernaderos - Sustrato y Otros',
             'Sustrato-Material',
             'Sustratos, bandejas, bolsas de crecimiento, mulch, saran y materiales de invernadero. Incluye Jiffy, QTS.')
ON CONFLICT (nk_categoria) DO NOTHING;

COMMENT ON TABLE dim_categoria IS
  'Dimensión conformada de categorías de inventario. '
  'Jerarquía: Tipo de Producto (Granular/Líquido/Sustrato) → Categoría.';


-- --------------------------------------------------------------------------------------------------------------------------------
--  4.4 DIM_PRODUCTO — Dimensión principal con SCD Tipo 2
--
--  SCD Tipo 2 (Slowly Changing Dimension):
--    Cuando cambia nombre_producto, presentacion o fecha_vencimiento,
--    se cierra la versión actual (fecha_fin_vigencia = ayer, es_registro_activo = FALSE)
--    y se inserta un nuevo registro con la información actualizada.
--    Esto preserva el historial completo para análisis de tendencias.
--
--  Atributos SCD Tipo 1 (se sobreescriben sin historial):
--    dias_para_vencer, clasificacion_venc (cambian con cada carga).
--
--  La llave natural (nk_codigo_producto) puede tener múltiples sk_producto;
--  solo uno tiene es_registro_activo = TRUE en cada momento.
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_producto (
    sk_producto            SERIAL        PRIMARY KEY,    -- Llave subrogada: nueva versión por cada cambio SCD2
    nk_codigo_producto     VARCHAR(30)   NOT NULL,       -- Llave natural: código del sistema David (limpio, sin apóstrofe)
    nombre_producto        VARCHAR(250)  NOT NULL,       -- Nombre completo normalizado
    sk_marca               INT           NOT NULL REFERENCES dim_marca(sk_marca),
    sk_categoria           INT           NOT NULL REFERENCES dim_categoria(sk_categoria),
    presentacion           VARCHAR(60),                  -- Extraída del nombre: "50 Kg", "5 Lt", "CJ2816"…
    codigo_estado_lote     VARCHAR(10),                  -- Estado del lote en sistema David: 569, 905, 1239…
    descripcion_estado_lote VARCHAR(40),                 -- Descripción: "Disponible", "En Cuarentena"…
    -- Atributos de vencimiento (SCD Tipo 2: si cambia la fecha, se crea nueva versión)
    fecha_vencimiento      DATE,                         -- Fecha de expiración del lote; NULL si no aplica
    -- Atributos de vencimiento (SCD Tipo 1: se actualizan in-place en cada carga)
    dias_para_vencer       INT,                          -- Días desde CURRENT_DATE hasta fecha_vencimiento
    clasificacion_venc     VARCHAR(20)   NOT NULL DEFAULT 'Sin Vencimiento'
                           CHECK (clasificacion_venc IN
                               ('Vencido','Critico','Alerta','Vigilancia','Normal','Sin Vencimiento')),
    dias_almacenaje_max    INT,                          -- Días máximos de almacenaje permitidos (de la hoja Jiffy)
    -- Control SCD Tipo 2
    fecha_inicio_vigencia  DATE          NOT NULL DEFAULT CURRENT_DATE,  -- Inicio de validez de esta versión
    fecha_fin_vigencia     DATE          NOT NULL DEFAULT '9999-12-31',  -- 9999-12-31 = versión vigente (abierta)
    es_registro_activo     BOOLEAN       NOT NULL DEFAULT TRUE,          -- TRUE = versión actual
    -- Fila especial para integridad referencial
    es_sin_definir         BOOLEAN       NOT NULL DEFAULT FALSE
);

-- Índice sobre la llave natural para la lógica SCD2 (cierre de versiones)
CREATE INDEX IF NOT EXISTS idx_dim_prod_nk      ON dim_producto (nk_codigo_producto);
-- Índice parcial para consultas que solo necesitan la versión activa (el caso más frecuente)
CREATE INDEX IF NOT EXISTS idx_dim_prod_activo  ON dim_producto (nk_codigo_producto)
    WHERE es_registro_activo = TRUE;
-- Índice para alertas de vencimiento próximo
CREATE INDEX IF NOT EXISTS idx_dim_prod_venc    ON dim_producto (fecha_vencimiento, clasificacion_venc)
    WHERE fecha_vencimiento IS NOT NULL AND es_registro_activo = TRUE;
-- Índice para filtrar por categoría y marca (consultas de distribución)
CREATE INDEX IF NOT EXISTS idx_dim_prod_catmarca ON dim_producto (sk_categoria, sk_marca)
    WHERE es_registro_activo = TRUE;

COMMENT ON TABLE dim_producto IS
  'Dimensión principal de SKUs con soporte SCD Tipo 2. '
  'Cada cambio en nombre, presentación o fecha_vencimiento genera una nueva fila '
  'manteniendo el historial completo. Usar WHERE es_registro_activo = TRUE para '
  'la versión actual de cada producto.';
COMMENT ON COLUMN dim_producto.nk_codigo_producto IS
  'Llave natural del sistema David, limpia: sin apóstrofe de formato Excel ('') ni espacios.';
COMMENT ON COLUMN dim_producto.fecha_fin_vigencia IS
  'Fecha hasta la que aplica esta versión. 9999-12-31 significa que es la versión vigente (SCD2 abierta).';

-- Fila "Producto Desconocido" para integridad referencial sin nulos en hechos
INSERT INTO dim_producto (
    nk_codigo_producto, nombre_producto,
    sk_marca, sk_categoria,
    fecha_inicio_vigencia, fecha_fin_vigencia,
    es_registro_activo, es_sin_definir
)
SELECT
    'SIN_PRODUCTO', 'Producto Sin Definir',
    m.sk_marca, c.sk_categoria,
    '1900-01-01', '9999-12-31', TRUE, TRUE
FROM dim_marca    m WHERE m.nk_marca     = 'SIN_MARCA'
JOIN dim_categoria c ON c.nk_categoria  = 'ND'
ON CONFLICT DO NOTHING;


-- --------------------------------------------------------------------------------------------------------------------------------
--  4.5 DIM_ESTADO_STOCK — Clasificación operacional del estado de cada SKU
--
--  El estado se deriva de la combinación de stock físico, saldo del sistema
--  y la diferencia entre ambos. Es una dimensión pequeña (junk dimension)
--  que evita repetir esta lógica de clasificación en las tablas de hechos.
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_estado_stock (
    sk_estado_stock  SERIAL       PRIMARY KEY,
    nk_estado        VARCHAR(30)  NOT NULL UNIQUE,       -- Código natural del estado
    nombre_estado    VARCHAR(50)  NOT NULL,              -- Nombre descriptivo
    descripcion      VARCHAR(200),                       -- Explicación de cuándo aplica este estado
    es_disponible    BOOLEAN      NOT NULL,              -- TRUE = el producto puede despacharse
    requiere_accion  BOOLEAN      NOT NULL DEFAULT FALSE,-- TRUE = exige intervención operativa inmediata
    color_semaforo   VARCHAR(10)                         -- 'Verde', 'Amarillo', 'Rojo' (para dashboards)
                     CHECK (color_semaforo IN ('Verde','Amarillo','Rojo','Gris'))
);

INSERT INTO dim_estado_stock
    (nk_estado, nombre_estado, descripcion, es_disponible, requiere_accion, color_semaforo)
VALUES
    ('DISP_OK',
     'Disponible — Sin Discrepancia',
     'Stock físico mayor a cero y coincide exactamente con el sistema.',
     TRUE, FALSE, 'Verde'),
    ('DISP_FALT',
     'Disponible — Faltante',
     'Hay stock físico pero el sistema registra más. Posible pérdida no justificada.',
     TRUE, TRUE, 'Amarillo'),
    ('DISP_SOBRANTE',
     'Disponible — Sobrante',
     'Hay stock físico pero el sistema registra menos. Posible ingreso no registrado.',
     TRUE, TRUE, 'Amarillo'),
    ('SIN_STOCK',
     'Sin Stock',
     'Inventario físico y sistema ambos en cero. Producto agotado.',
     FALSE, FALSE, 'Gris'),
    ('AGOTADO_DESAC',
     'Agotado — Sistema Desactualizado',
     'Físico en cero pero el sistema dice que hay existencia. Discrepancia crítica.',
     FALSE, TRUE, 'Rojo'),
    ('PEND_REVISION',
     'Pendiente de Revisión',
     'Estado indeterminado. Requiere segundo conteo o verificación documental.',
     FALSE, TRUE, 'Rojo')
ON CONFLICT (nk_estado) DO NOTHING;

COMMENT ON TABLE dim_estado_stock IS
  'Junk dimension con la clasificación operacional del estado de inventario de cada SKU. '
  'Se deriva de la combinación de cantidad física, saldo sistema y diferencia entre ambos.';


-- --------------------------------------------------------------------------------------------------------------------------------
--  4.6 DIM_TIPO_DISCREPANCIA — Causas de las discrepancias de inventario
--
--  Valores derivados de las observaciones de texto libre del archivo Excel.
--  Permite analizar el inventario de discrepancias agrupado por causa,
--  calcular el impacto financiero de cada tipo y priorizar acciones correctivas.
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_tipo_discrepancia (
    sk_tipo_disc       SERIAL       PRIMARY KEY,
    nk_tipo_disc       VARCHAR(10)  NOT NULL UNIQUE,     -- Código corto (PR, EP, FF, SNR…)
    nombre_tipo        VARCHAR(80)  NOT NULL UNIQUE,     -- Nombre del tipo de discrepancia
    descripcion        VARCHAR(300),
    impacto_financiero VARCHAR(5)   NOT NULL DEFAULT 'Bajo'
                       CHECK (impacto_financiero IN ('Alto','Medio','Bajo')),
    afecta_activos     BOOLEAN      NOT NULL DEFAULT FALSE, -- TRUE = implica diferencia en valor del activo
    accion_recomendada VARCHAR(300)
);

INSERT INTO dim_tipo_discrepancia
    (nk_tipo_disc, nombre_tipo, descripcion, impacto_financiero, afecta_activos, accion_recomendada)
VALUES
    ('PR',  'Pendiente Rebajar',
            'Movimiento físico realizado (salida) pero no registrado en el sistema David.',
            'Alto', TRUE,
            'Ejecutar la transacción de salida en Sistema David.'),
    ('EP',  'Entrega Pendiente',
            'Producto físicamente recibido en bodega pero no ingresado al sistema.',
            'Medio', TRUE,
            'Registrar el ingreso de mercancía en el sistema.'),
    ('FF',  'Faltante Físico',
            'Menos unidades físicas que lo registrado en el sistema sin explicación.',
            'Alto', TRUE,
            'Investigar causa (robo/merma/error). Ajuste negativo autorizado por gerencia.'),
    ('SNR', 'Sobrante No Registrado',
            'Más unidades físicas que lo registrado en el sistema. Activo no contabilizado.',
            'Alto', TRUE,
            'Registrar el ingreso al sistema con costo correspondiente.'),
    ('SCN', 'Sobrante Con Nota',
            'Sobrante con observación que explica parcialmente la diferencia.',
            'Medio', FALSE,
            'Revisar la observación y ajustar o documentar según corresponda.'),
    ('FCN', 'Faltante Con Nota',
            'Faltante con observación que explica parcialmente la diferencia.',
            'Medio', TRUE,
            'Revisar la observación y gestionar ajuste autorizado.'),
    ('SSJ', 'Sobrante Sin Justificar',
            'Sobrante sin observación. Requiere investigación antes de ajustar.',
            'Bajo', FALSE,
            'Realizar segundo conteo y documentar hallazgo.'),
    ('FSJ', 'Faltante Sin Justificar',
            'Faltante sin observación. Requiere investigación antes de ajustar.',
            'Bajo', TRUE,
            'Realizar segundo conteo y documentar hallazgo.'),
    ('ND',  'Sin Discrepancia',
            'No hay diferencia entre el conteo físico y el sistema.',
            'Bajo', FALSE,
            'Sin acción requerida. Inventario exacto.')
ON CONFLICT (nk_tipo_disc) DO NOTHING;

COMMENT ON TABLE dim_tipo_discrepancia IS
  'Catálogo de causas de discrepancia derivadas de las observaciones de texto libre del archivo fuente. '
  'Permite agrupar y priorizar las acciones correctivas por tipo e impacto financiero.';


-- ================================================================================================================================
--  SECCIÓN 5: TABLAS DE HECHOS
-- ================================================================================================================================

-- --------------------------------------------------------------------------------------------------------------------------------
--  5.1 FACT_INVENTARIO — Tabla de hechos principal
--
--  Granularidad: 1 fila = 1 SKU * 1 toma física (fecha).
--  "Un registro por producto por evento de auditoría de inventario."
--
--  Medidas aditivas    : cantidad_fisica, cantidad_sistema
--                        (se pueden sumar entre cualquier combinación de dimensiones)
--  Medidas derivadas   : diferencia_unids, flag_discrepancia, flag_stock_cero
--                        (calculadas automáticamente por PostgreSQL mediante columnas generadas)
--  Medidas semi-aditivas: los flags no deben sumarse entre fechas, solo contarse.
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fact_inventario (
    -- ── Llaves foráneas a dimensiones ────────────────────────────────────────
    sk_tiempo          INT           NOT NULL REFERENCES dim_tiempo(sk_tiempo),
    sk_producto        INT           NOT NULL REFERENCES dim_producto(sk_producto),
    sk_categoria       INT           NOT NULL REFERENCES dim_categoria(sk_categoria),
    sk_marca           INT           NOT NULL REFERENCES dim_marca(sk_marca),
    sk_estado_stock    INT           NOT NULL REFERENCES dim_estado_stock(sk_estado_stock),
    -- ── Medidas del negocio ──────────────────────────────────────────────────
    cantidad_fisica    NUMERIC(12,2) NOT NULL DEFAULT 0   -- Unidades contadas en la toma física (hoja: "Fisico")
                       CHECK (cantidad_fisica >= 0),
    cantidad_sistema   NUMERIC(12,2) NOT NULL DEFAULT 0   -- Saldo según sistema David (hoja: "Sist. David")
                       CHECK (cantidad_sistema >= 0),
    -- ── Columnas generadas (derivadas automáticamente por PostgreSQL) ────────
    -- Columna generada STORED: se persiste en disco, no se recalcula en cada SELECT
    diferencia_unids   NUMERIC(12,2) GENERATED ALWAYS AS
                       (cantidad_fisica - cantidad_sistema) STORED,
                       -- Positivo = sobrante (más físico que sistema)
                       -- Negativo = faltante (menos físico que sistema)
    flag_discrepancia  BOOLEAN       GENERATED ALWAYS AS
                       (cantidad_fisica <> cantidad_sistema) STORED,
                       -- TRUE si hay cualquier diferencia, independientemente del sentido
    flag_stock_cero    BOOLEAN       GENERATED ALWAYS AS
                       (cantidad_fisica = 0) STORED,
                       -- TRUE si el inventario físico está agotado
    -- ── Trazabilidad ETL ────────────────────────────────────────────────────
    id_carga_origen    INT,                               -- FK al id_carga de stg_carga (trazabilidad al archivo fuente)
    fecha_carga_dw     TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    -- ── Clave primaria compuesta ─────────────────────────────────────────────
    -- Un SKU aparece una sola vez por toma física
    PRIMARY KEY (sk_tiempo, sk_producto)
);

-- Índice para el KPI más frecuente: análisis de discrepancias por toma física
CREATE INDEX IF NOT EXISTS idx_fi_disc
    ON fact_inventario (sk_tiempo, sk_categoria)
    WHERE flag_discrepancia = TRUE;

-- Índice para KPI de quiebre de stock
CREATE INDEX IF NOT EXISTS idx_fi_cero
    ON fact_inventario (sk_tiempo, sk_categoria)
    WHERE flag_stock_cero = TRUE;

-- Índice para análisis por marca (PB-05: distribución por marca)
CREATE INDEX IF NOT EXISTS idx_fi_marca
    ON fact_inventario (sk_tiempo, sk_marca);

-- Índice para análisis por estado de stock
CREATE INDEX IF NOT EXISTS idx_fi_estado
    ON fact_inventario (sk_tiempo, sk_estado_stock);

COMMENT ON TABLE fact_inventario IS
  'Tabla de hechos principal. Granularidad: 1 fila = 1 SKU * 1 toma física. '
  'Medidas: cantidad física, cantidad sistema (aditivas) y diferencia/flags (derivadas). '
  'Clave primaria compuesta: (sk_tiempo, sk_producto).';
COMMENT ON COLUMN fact_inventario.diferencia_unids IS
  'Columna generada STORED: cantidad_fisica - cantidad_sistema. '
  'Positivo = sobrante; Negativo = faltante. No se puede modificar directamente.';


-- --------------------------------------------------------------------------------------------------------------------------------
--  5.2 FACT_DISCREPANCIA — Tabla de hechos secundaria
--
--  Granularidad: 1 fila = 1 SKU con diferencia ≠ 0 * 1 toma física.
--  Solo contiene productos donde se detectó discrepancia.
--
--  Propósito: Facilitar análisis específicos de discrepancias sin
--  escanear toda la tabla FACT_INVENTARIO (que incluye los ~93% sin diferencia).
--  Los análisis de causa raíz, impacto financiero y tipología de error
--  se realizan sobre esta tabla.
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fact_discrepancia (
    -- ── Llaves foráneas ───────────────────────────────────────────────────────
    sk_tiempo            INT           NOT NULL REFERENCES dim_tiempo(sk_tiempo),
    sk_producto          INT           NOT NULL REFERENCES dim_producto(sk_producto),
    sk_categoria         INT           NOT NULL REFERENCES dim_categoria(sk_categoria),
    sk_marca             INT           NOT NULL REFERENCES dim_marca(sk_marca),
    sk_tipo_disc         INT           NOT NULL REFERENCES dim_tipo_discrepancia(sk_tipo_disc),
    -- ── Medidas ───────────────────────────────────────────────────────────────
    unidades_diferencia  NUMERIC(12,2) NOT NULL                             -- Valor ABSOLUTO de la diferencia
                         CHECK (unidades_diferencia > 0),
    signo_diferencia     CHAR(1)       NOT NULL                             -- '+' = sobrante | '-' = faltante
                         CHECK (signo_diferencia IN ('+','-')),
    cantidad_fisica      NUMERIC(12,2) NOT NULL DEFAULT 0,                  -- Desnormalizado para evitar JOIN con FACT_INVENTARIO
    cantidad_sistema     NUMERIC(12,2) NOT NULL DEFAULT 0,
    -- ── Atributos del hecho ──────────────────────────────────────────────────
    observacion_texto    VARCHAR(500),                                      -- Texto original de la observación operacional
    -- ── Trazabilidad ETL ────────────────────────────────────────────────────
    id_carga_origen      INT,
    fecha_carga_dw       TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    -- ── Clave primaria compuesta ─────────────────────────────────────────────
    PRIMARY KEY (sk_tiempo, sk_producto)
);

-- Índice para análisis por tipo de discrepancia (PB-06: Pendiente por Rebajar)
CREATE INDEX IF NOT EXISTS idx_fd_tipo
    ON fact_discrepancia (sk_tiempo, sk_tipo_disc);

-- Índice para análisis por categoría y magnitud
CREATE INDEX IF NOT EXISTS idx_fd_cat_unidades
    ON fact_discrepancia (sk_tiempo, sk_categoria, unidades_diferencia DESC);

COMMENT ON TABLE fact_discrepancia IS
  'Tabla de hechos secundaria: solo SKUs con diferencia ≠ 0 en la toma física. '
  'Granularidad: 1 fila = 1 discrepancia * 1 toma física. '
  'Facilita análisis de causa raíz y priorización de ajustes sin escanear FACT_INVENTARIO completa.';


-- ================================================================================================================================
--  SECCIÓN 6: VISTAS ANALÍTICAS (KPIs PRE-CALCULADOS)
--  Encapsulan las consultas más frecuentes como vistas reutilizables.
-- ================================================================================================================================

-- --------------------------------------------------------------------------------------------------------------------------------
--  6.1 V_KPI_IRA — Inventory Record Accuracy por categoría y toma física
--  KPI principal: (SKUs sin diferencia / Total SKUs) * 100
--  Meta: > 95%
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_kpi_ira AS
SELECT
    t.sk_tiempo,
    t.fecha_completa                                                           AS fecha_toma,
    t.anio,
    t.nombre_mes,
    c.nombre_categoria,
    c.tipo_producto,
    COUNT(*)                                                                   AS total_skus,
    SUM(CASE WHEN fi.flag_discrepancia = FALSE THEN 1 ELSE 0 END)             AS skus_exactos,
    SUM(CASE WHEN fi.flag_discrepancia = TRUE  THEN 1 ELSE 0 END)             AS skus_con_diferencia,
    -- IRA como porcentaje
    ROUND(
        SUM(CASE WHEN fi.flag_discrepancia = FALSE THEN 1.0 ELSE 0 END)
        / NULLIF(COUNT(*), 0) * 100, 2
    )                                                                          AS ira_pct,
    -- Indicador de cumplimiento de meta (> 95%)
    CASE
        WHEN ROUND(SUM(CASE WHEN fi.flag_discrepancia = FALSE THEN 1.0 ELSE 0 END)
             / NULLIF(COUNT(*), 0) * 100, 2) >= 95 THEN 'Cumple'
        ELSE 'Bajo Meta'
    END                                                                        AS estado_meta,
    SUM(fi.cantidad_fisica)                                                    AS total_unidades_fisicas,
    SUM(fi.cantidad_sistema)                                                   AS total_unidades_sistema,
    SUM(fi.diferencia_unids)                                                   AS diferencia_neta
FROM fact_inventario fi
JOIN dim_tiempo    t USING (sk_tiempo)
JOIN dim_categoria c USING (sk_categoria)
GROUP BY t.sk_tiempo, t.fecha_completa, t.anio, t.nombre_mes,
         c.nombre_categoria, c.tipo_producto;

COMMENT ON VIEW v_kpi_ira IS
  'KPI de Inventory Record Accuracy (IRA) por categoría y fecha de toma física. Meta: IRA ≥ 95%.';


-- --------------------------------------------------------------------------------------------------------------------------------
--  6.2 V_KPI_QUIEBRE — Porcentaje de quiebre de stock por categoría
--  KPI: (SKUs con stock físico = 0 / Total SKUs) * 100
--  Meta: < 10%
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_kpi_quiebre AS
SELECT
    t.sk_tiempo,
    t.fecha_completa                                                           AS fecha_toma,
    c.nombre_categoria,
    COUNT(*)                                                                   AS total_skus,
    SUM(CASE WHEN fi.flag_stock_cero = TRUE  THEN 1 ELSE 0 END)              AS skus_sin_stock,
    SUM(CASE WHEN fi.flag_stock_cero = FALSE THEN 1 ELSE 0 END)              AS skus_con_stock,
    ROUND(
        SUM(CASE WHEN fi.flag_stock_cero = TRUE THEN 1.0 ELSE 0 END)
        / NULLIF(COUNT(*), 0) * 100, 2
    )                                                                          AS pct_quiebre,
    -- SKUs agotados que el sistema aún reporta con saldo (discrepancia crítica)
    SUM(CASE
        WHEN fi.flag_stock_cero = TRUE AND fi.cantidad_sistema > 0
        THEN 1 ELSE 0 END)                                                    AS agotados_no_reconocidos
FROM fact_inventario fi
JOIN dim_tiempo    t USING (sk_tiempo)
JOIN dim_categoria c USING (sk_categoria)
GROUP BY t.sk_tiempo, t.fecha_completa, c.nombre_categoria;

COMMENT ON VIEW v_kpi_quiebre IS
  'KPI de quiebre de stock por categoría y toma física. Meta: porcentaje de quiebre < 10%.';


-- --------------------------------------------------------------------------------------------------------------------------------
--  6.3 V_PRODUCTOS_RIESGO_VENCIMIENTO — Productos próximos a vencer
--  Muestra solo SKUs activos con fecha de vencimiento en los próximos 12 meses.
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_productos_riesgo_vencimiento AS
SELECT
    p.nk_codigo_producto,
    p.nombre_producto,
    m.nombre_marca,
    c.nombre_categoria,
    p.fecha_vencimiento,
    p.dias_para_vencer,
    p.clasificacion_venc,
    ROUND(p.dias_para_vencer / 30.0, 1)                                        AS meses_restantes
FROM dim_producto  p
JOIN dim_marca     m ON m.sk_marca     = p.sk_marca
JOIN dim_categoria c ON c.sk_categoria = p.sk_categoria
WHERE p.es_registro_activo   = TRUE
  AND p.fecha_vencimiento    IS NOT NULL
  AND p.dias_para_vencer     BETWEEN 0 AND 365
ORDER BY p.dias_para_vencer ASC;

COMMENT ON VIEW v_productos_riesgo_vencimiento IS
  'Productos activos con fecha de vencimiento en los próximos 12 meses. '
  'Responde a la pregunta de negocio PB-04.';


-- ================================================================================================================================
--  SECCIÓN 7: CONSULTAS ANALÍTICAS — RESPUESTA A PREGUNTAS DE NEGOCIO
--  Las consultas se parametrizan por sk_tiempo para que sirvan para cualquier toma física.
--  Reemplazar el literal 20260525 por el sk_tiempo de la toma a analizar.
-- ================================================================================================================================

-- --------------------------------------------------------------------------------------------------------------------------------
--  PB-01: ¿Cuál es la tasa de exactitud de inventario (IRA) por categoría?
--  KPI: IRA = (SKUs sin diferencia / Total SKUs) * 100 — Meta: > 95%
-- --------------------------------------------------------------------------------------------------------------------------------
/*
SELECT *
FROM v_kpi_ira
WHERE sk_tiempo = 20260525
ORDER BY ira_pct ASC;  -- Las peores categorías primero para priorizar acción
*/


-- --------------------------------------------------------------------------------------------------------------------------------
--  PB-02: ¿Qué productos tienen discrepancias y cuál es la causa y magnitud?
-- --------------------------------------------------------------------------------------------------------------------------------
/*
SELECT
    p.nk_codigo_producto                                 AS codigo,
    p.nombre_producto,
    c.nombre_categoria,
    m.nombre_marca,
    fi.cantidad_fisica,
    fi.cantidad_sistema,
    fi.diferencia_unids,
    CASE
        WHEN fi.diferencia_unids > 0 THEN 'Sobrante (Físico > Sistema)'
        ELSE 'Faltante (Sistema > Físico)'
    END                                                  AS tipo_diferencia,
    td.nombre_tipo                                       AS causa,
    td.impacto_financiero,
    fd.observacion_texto
FROM fact_inventario fi
JOIN fact_discrepancia fd    USING (sk_tiempo, sk_producto)
JOIN dim_producto p          USING (sk_producto)
JOIN dim_categoria c         USING (sk_categoria)
JOIN dim_marca m             USING (sk_marca)
JOIN dim_tipo_discrepancia td ON td.sk_tipo_disc = fd.sk_tipo_disc
WHERE fi.sk_tiempo = 20260525
ORDER BY ABS(fi.diferencia_unids) DESC;
*/


-- --------------------------------------------------------------------------------------------------------------------------------
--  PB-03: ¿Cuántos productos tienen stock físico = 0? (Quiebre de stock)
--  KPI: % Quiebre = (SKUs stock 0 / Total SKUs) * 100 — Meta: < 10%
-- --------------------------------------------------------------------------------------------------------------------------------
/*
SELECT *
FROM v_kpi_quiebre
WHERE sk_tiempo = 20260525

UNION ALL

SELECT
    20260525,
    (SELECT fecha_completa FROM dim_tiempo WHERE sk_tiempo = 20260525),
    'TOTAL GLOBAL',
    COUNT(*),
    SUM(CASE WHEN flag_stock_cero = TRUE  THEN 1 ELSE 0 END),
    SUM(CASE WHEN flag_stock_cero = FALSE THEN 1 ELSE 0 END),
    ROUND(SUM(CASE WHEN flag_stock_cero = TRUE THEN 1.0 ELSE 0 END) / NULLIF(COUNT(*),0) * 100, 2),
    SUM(CASE WHEN flag_stock_cero = TRUE AND cantidad_sistema > 0 THEN 1 ELSE 0 END)
FROM fact_inventario
WHERE sk_tiempo = 20260525;
*/


-- --------------------------------------------------------------------------------------------------------------------------------
--  PB-04: ¿Qué productos están próximos a vencer en los próximos 12 meses?
-- --------------------------------------------------------------------------------------------------------------------------------
/*
SELECT
    v.*,
    fi.cantidad_fisica AS stock_disponible
FROM v_productos_riesgo_vencimiento v
JOIN dim_producto p ON p.nombre_producto = v.nombre_producto AND p.es_registro_activo = TRUE
JOIN fact_inventario fi ON fi.sk_producto = p.sk_producto
WHERE fi.sk_tiempo   = 20260525
  AND fi.cantidad_fisica > 0
ORDER BY v.dias_para_vencer ASC;
*/


-- --------------------------------------------------------------------------------------------------------------------------------
--  PB-05: ¿Cuál es la distribución del inventario por marca?
-- --------------------------------------------------------------------------------------------------------------------------------
/*
SELECT
    m.nombre_marca,
    m.tipo_proveedor,
    COUNT(DISTINCT fi.sk_producto)                           AS num_skus,
    SUM(fi.cantidad_fisica)                                  AS total_stock_fisico,
    SUM(fi.cantidad_sistema)                                 AS total_stock_sistema,
    ROUND(
        SUM(fi.cantidad_fisica)
        / NULLIF(SUM(SUM(fi.cantidad_fisica)) OVER (), 0) * 100, 2
    )                                                        AS pct_del_total,
    SUM(CASE WHEN fi.flag_discrepancia = TRUE THEN 1 ELSE 0 END) AS skus_con_discrepancia
FROM fact_inventario fi
JOIN dim_marca m USING (sk_marca)
WHERE fi.sk_tiempo = 20260525
GROUP BY m.nombre_marca, m.tipo_proveedor
ORDER BY total_stock_fisico DESC;
*/


-- --------------------------------------------------------------------------------------------------------------------------------
--  PB-06: ¿Cuáles son los productos con "Pendiente por Rebajar"?
-- --------------------------------------------------------------------------------------------------------------------------------
/*
SELECT
    p.nk_codigo_producto,
    p.nombre_producto,
    c.nombre_categoria,
    fi.cantidad_fisica,
    fi.cantidad_sistema,
    ABS(fi.diferencia_unids)                               AS unidades_pendientes,
    fd.observacion_texto,
    SUM(ABS(fi.diferencia_unids)) OVER (
        ORDER BY ABS(fi.diferencia_unids) DESC
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                                      AS acumulado_pendiente
FROM fact_inventario fi
JOIN fact_discrepancia fd       USING (sk_tiempo, sk_producto)
JOIN dim_producto p             USING (sk_producto)
JOIN dim_categoria c            USING (sk_categoria)
JOIN dim_tipo_discrepancia td   ON td.sk_tipo_disc = fd.sk_tipo_disc
WHERE fi.sk_tiempo = 20260525
  AND td.nk_tipo_disc = 'PR'
ORDER BY ABS(fi.diferencia_unids) DESC;
*/


-- --------------------------------------------------------------------------------------------------------------------------------
--  DASHBOARD EJECUTIVO — KPIs consolidados en una sola consulta
-- --------------------------------------------------------------------------------------------------------------------------------
/*
SELECT
    (SELECT fecha_completa FROM dim_tiempo WHERE sk_tiempo = 20260525) AS fecha_toma,

    -- IRA Global
    ROUND(SUM(CASE WHEN flag_discrepancia = FALSE THEN 1.0 ELSE 0 END)
          / NULLIF(COUNT(*),0) * 100, 2)                               AS ira_global_pct,

    -- % Quiebre de Stock
    ROUND(SUM(CASE WHEN flag_stock_cero = TRUE THEN 1.0 ELSE 0 END)
          / NULLIF(COUNT(*),0) * 100, 2)                               AS pct_quiebre_stock,

    -- Conteos absolutos
    COUNT(*)                                                            AS total_skus,
    SUM(CASE WHEN flag_discrepancia = TRUE  THEN 1 ELSE 0 END)        AS skus_con_discrepancia,
    SUM(CASE WHEN flag_stock_cero   = TRUE  THEN 1 ELSE 0 END)        AS skus_sin_stock,
    SUM(CASE WHEN flag_discrepancia = FALSE
          AND flag_stock_cero = FALSE       THEN 1 ELSE 0 END)        AS skus_ok,

    -- Volumen de inventario
    SUM(cantidad_fisica)                                                AS total_unidades_fisicas,
    SUM(cantidad_sistema)                                               AS total_unidades_sistema,
    SUM(diferencia_unids)                                               AS diferencia_neta_total,

    -- Desglose por sentido de diferencia
    SUM(CASE WHEN diferencia_unids > 0 THEN diferencia_unids  ELSE 0 END) AS total_sobrante_uds,
    ABS(SUM(CASE WHEN diferencia_unids < 0 THEN diferencia_unids ELSE 0 END)) AS total_faltante_uds

FROM fact_inventario
WHERE sk_tiempo = 20260525;
*/