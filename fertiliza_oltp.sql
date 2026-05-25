-- ================================================================================================================================
--  ARCHIVO   : feltiliza_oltp.sql
--  PROYECTO  : Sistema de Gestión de Inventario
--  MÓDULO    : Modelo Operacional / Transaccional (OLTP)
--  BASE      : PostgreSQL 
--  SCHEMA    : fertiliza_oltp
--  VERSIÓN   : 1.0 - Mayo 2026
--
--  DESCRIPCIÓN:
--    Replica el modelo relacional normalizado que subyace el CSV. Este esquema representa la fuente operacional de la cual
--    se extraen los datos para el proceso ETL hacia el Data Warehouse.
--
--    Incluye además:
--      • Tablas de auditoría genéricas (audit_log) y por entidad.
--      • Tablas de staging para la recepción de archivos CSV/Excel.
--      • Triggers de auditoría automáticos en cada tabla maestra.
--
--  ORDEN DE EJECUCIÓN:
--    1. Schema y extensiones
--    2. Tablas maestras (catálogos)
--    3. Tablas transaccionales
--    4. Tablas de staging (importación CSV/Excel)
--    5. Tablas de auditoría
--    6. Funciones y triggers de auditoría
--    7. Índices operacionales
--    8. Datos iniciales de catálogos
-- ================================================================================================================================


-- ================================================================================================================================
--  SECCIÓN 1: SCHEMA, EXTENSIONES Y CONFIGURACIÓN INICIAL
-- ================================================================================================================================

-- Extensión para generar UUIDs (usados en la tabla de auditoría para IDs únicos de evento)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Extensión para búsqueda de texto (para observaciones y notas de inventario)
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Crear el schema operacional; IF NOT EXISTS evita error en re-ejecuciones
CREATE SCHEMA IF NOT EXISTS fertiliza_oltp;

-- Asignar search_path a la sesión para no tener que calificar cada objeto
SET search_path TO fertiliza_oltp;


-- ================================================================================================================================
--  SECCIÓN 2: TABLAS DE AUDITORÍA
--  Llas tablas de negocio las referenciarán mediante triggers.
-- ================================================================================================================================

-- --------------------------------------------------------------------------------------------------------------------------------
--  2.1 AUDIT_LOG - Bitácora general de cambios en todas las tablas del schema
--  Registra cada INSERT, UPDATE y DELETE con los valores anteriores y nuevos en formato JSONB.
--  Los triggers de cada tabla invocan la función fn_audit_trigger() que escribe aquí.
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_log (
    id_audit         UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),  -- Identificador único del evento de auditoría
    esquema          VARCHAR(50)  NOT NULL,                                  -- Schema donde ocurrió el cambio
    tabla            VARCHAR(100) NOT NULL,                                  -- Tabla afectada
    operacion        CHAR(6)      NOT NULL                                   -- 'INSERT', 'UPDATE' o 'DELETE'
                     CHECK (operacion IN ('INSERT','UPDATE','DELETE')),
    id_registro      TEXT,                                                   -- PK del registro afectado (como texto)
    valores_antes    JSONB,                                                  -- Snapshot del registro ANTES del cambio (NULL en INSERT)
    valores_despues  JSONB,                                                  -- Snapshot del registro DESPUÉS del cambio (NULL en DELETE)
    usuario_db       VARCHAR(100) NOT NULL DEFAULT current_user,             -- Usuario de base de datos que ejecutó la operación
    usuario_app      VARCHAR(100),                                           -- Usuario de la aplicación (ej. operario de bodega)
    ip_origen        INET,                                                   -- IP desde la que se originó la conexión
    timestamp_utc    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),                    -- Fecha y hora exacta en UTC
    descripcion      TEXT                                                    -- Comentario libre opcional (ej. "Ajuste por toma física")
);

-- Índices para consultas frecuentes en la bitácora
CREATE INDEX IF NOT EXISTS idx_audit_tabla     ON audit_log (tabla, timestamp_utc DESC);
CREATE INDEX IF NOT EXISTS idx_audit_operacion ON audit_log (operacion, timestamp_utc DESC);
CREATE INDEX IF NOT EXISTS idx_audit_usuario   ON audit_log (usuario_db, timestamp_utc DESC);
-- Índice GIN para búsquedas dentro del JSONB de valores
CREATE INDEX IF NOT EXISTS idx_audit_val_antes   ON audit_log USING GIN (valores_antes);
CREATE INDEX IF NOT EXISTS idx_audit_val_despues ON audit_log USING GIN (valores_despues);

COMMENT ON TABLE audit_log IS
  'Bitácora centralizada de auditoría. Registra automáticamente todos los cambios en las tablas del schema mediante triggers.';


-- --------------------------------------------------------------------------------------------------------------------------------
--  2.2 AUDIT_SESION — Registro de conexiones al sistema
--  Permite trazar quién accedió a la base de datos y cuándo.
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_sesion (
    id_sesion        SERIAL       PRIMARY KEY,
    usuario_db       VARCHAR(100) NOT NULL DEFAULT current_user,
    usuario_app      VARCHAR(100),
    ip_origen        INET,
    fecha_inicio     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    fecha_fin        TIMESTAMPTZ,
    descripcion      TEXT                                                    -- Ej. "Ejecución ETL carga mensual"
);

COMMENT ON TABLE audit_sesion IS
  'Registro de sesiones de trabajo: quién conectó, desde dónde y cuándo.';


-- ================================================================================================================================
--  SECCIÓN 3: TABLAS MAESTRAS (CATÁLOGOS)
--  Entidades de referencia con baja frecuencia de cambio.
-- ================================================================================================================================

-- --------------------------------------------------------------------------------------------------------------------------------
--  3.1 CATEGORIA_PRODUCTO — Categorías principales de inventario
--  Valores fuente del Excel: "Granular - Solubles", "Liquidos",
--  "Material para Invernaderos - Sustrato y Otros"
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS categoria_producto (
    id_categoria     SMALLSERIAL  PRIMARY KEY,
    codigo_categoria VARCHAR(10)  NOT NULL UNIQUE,                           -- Código corto (GS, LQ, MI)
    nombre           VARCHAR(120) NOT NULL UNIQUE,                           -- Nombre completo de la categoría
    tipo_producto    VARCHAR(30)  NOT NULL                                   -- Granular | Líquido | Sustrato-Material
                     CHECK (tipo_producto IN ('Granular','Líquido','Sustrato-Material','Otro')),
    descripcion      VARCHAR(400),                                           -- Descripción larga para reportes
    activo           BOOLEAN      NOT NULL DEFAULT TRUE,
    creado_en        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    modificado_en    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE categoria_producto IS
  'Catálogo de las categorías de inventario tal como se definen en el sistema David y la toma física.';


-- --------------------------------------------------------------------------------------------------------------------------------
--  3.2 MARCA_PROVEEDOR — Marcas / fabricantes de los productos
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS marca_proveedor (
    id_marca         SMALLSERIAL  PRIMARY KEY,
    nombre_marca     VARCHAR(80)  NOT NULL UNIQUE,                           -- Nombre canónico de la marca
    pais_origen      VARCHAR(50),                                            -- País del fabricante
    tipo_proveedor   VARCHAR(15)  NOT NULL DEFAULT 'Desconocido'             -- Nacional | Importado | Desconocido
                     CHECK (tipo_proveedor IN ('Nacional','Importado','Desconocido')),
    contacto_nombre  VARCHAR(120),                                           -- Nombre del representante o contacto
    contacto_email   VARCHAR(120),
    activo           BOOLEAN      NOT NULL DEFAULT TRUE,
    creado_en        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    modificado_en    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE marca_proveedor IS
  'Catálogo de marcas y proveedores. Cada producto pertenece a exactamente una marca.';


-- --------------------------------------------------------------------------------------------------------------------------------
--  3.3 UNIDAD_MEDIDA — Unidades de medida de inventario
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS unidad_medida (
    id_unidad        SMALLSERIAL  PRIMARY KEY,
    codigo           VARCHAR(10)  NOT NULL UNIQUE,                           -- Kg, Lt, G, Un, CJ, Ro
    descripcion      VARCHAR(60)  NOT NULL,                                  -- Kilogramo, Litro, Gramo, Unidad, Caja, Rollo
    activo           BOOLEAN      NOT NULL DEFAULT TRUE,
    creado_en        TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE unidad_medida IS
  'Catálogo de unidades de medida utilizadas en el inventario (Kg, Lt, G, Unidad, Caja, Rollo).';


-- --------------------------------------------------------------------------------------------------------------------------------
--  3.4 BODEGA — Ubicaciones físicas de almacenamiento
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bodega (
    id_bodega        SMALLSERIAL  PRIMARY KEY,
    codigo_bodega    VARCHAR(10)  NOT NULL UNIQUE,
    nombre           VARCHAR(80)  NOT NULL,
    tipo_almacenaje  VARCHAR(30)  NOT NULL DEFAULT 'General'
                     CHECK (tipo_almacenaje IN ('General','Área Especial','En Tránsito','Cuarentena')),
    temperatura_ctrl BOOLEAN      NOT NULL DEFAULT FALSE,                    -- TRUE = requiere control de temperatura (biológicos)
    activo           BOOLEAN      NOT NULL DEFAULT TRUE,
    creado_en        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    modificado_en    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE bodega IS
  'Catálogo de bodegas y zonas de almacenamiento. La bodega principal es la Bodega Central Fertilisa.';


-- --------------------------------------------------------------------------------------------------------------------------------
--  3.5 TIPO_MOVIMIENTO — Tipos de movimiento de inventario
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tipo_movimiento (
    id_tipo_mov      SMALLSERIAL  PRIMARY KEY,
    codigo           VARCHAR(10)  NOT NULL UNIQUE,                           -- ENT, SAL, AJP, AJN, DEV, TRF
    descripcion      VARCHAR(80)  NOT NULL,                                  -- Entrada, Salida, Ajuste Positivo, etc.
    afecta_stock     SMALLINT     NOT NULL                                   -- +1 = aumenta stock, -1 = disminuye
                     CHECK (afecta_stock IN (1, -1)),
    requiere_doc     BOOLEAN      NOT NULL DEFAULT TRUE,                     -- TRUE = exige número de documento de respaldo
    activo           BOOLEAN      NOT NULL DEFAULT TRUE,
    creado_en        TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE tipo_movimiento IS
  'Catálogo de tipos de movimiento de inventario: entradas, salidas, ajustes, devoluciones y transferencias.';


-- --------------------------------------------------------------------------------------------------------------------------------
--  3.6 TIPO_DISCREPANCIA — Causas posibles de discrepancias en toma física
--  Se deriva de las observaciones de texto libre del archivo fuente.
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tipo_discrepancia (
    id_tipo_disc     SMALLSERIAL  PRIMARY KEY,
    codigo           VARCHAR(10)  NOT NULL UNIQUE,
    nombre           VARCHAR(80)  NOT NULL UNIQUE,
    impacto          VARCHAR(5)   NOT NULL DEFAULT 'Bajo'
                     CHECK (impacto IN ('Alto','Medio','Bajo')),
    accion_sugerida  VARCHAR(300),                                           -- Acción correctiva recomendada
    activo           BOOLEAN      NOT NULL DEFAULT TRUE,
    creado_en        TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE tipo_discrepancia IS
  'Catálogo de causas de discrepancia entre el inventario físico y el sistema ERP David.';


-- ================================================================================================================================
--  SECCIÓN 4: TABLAS TRANSACCIONALES
--  Entidades con alta frecuencia de escritura / lectura.
-- ================================================================================================================================

-- --------------------------------------------------------------------------------------------------------------------------------
--  4.1 PRODUCTO — Catálogo maestro de SKUs
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS producto (
    id_producto        SERIAL        PRIMARY KEY,
    codigo_producto    VARCHAR(30)   NOT NULL UNIQUE,                        -- PK natural
    nombre             VARCHAR(250)  NOT NULL,                               -- Nombre completo del SKU
    id_categoria       SMALLINT      NOT NULL REFERENCES categoria_producto(id_categoria),
    id_marca           SMALLINT      NOT NULL REFERENCES marca_proveedor(id_marca),
    id_unidad          SMALLINT      NOT NULL REFERENCES unidad_medida(id_unidad),
    presentacion       VARCHAR(60),                                          -- Ej.: "50 Kg", "5 Lt", "250 G", "CJ2816"
    fecha_vencimiento  DATE,                                                 -- Fecha de expiración del lote actual (NULL si no aplica)
    dias_almacenaje    INT,                                                  -- Días máximos de almacenamiento permitidos
    codigo_estado_lote VARCHAR(10),                                          -- Código del estado del lote en sistema (569, 905, 1239…)
    stock_minimo       NUMERIC(12,2) NOT NULL DEFAULT 0,                     -- Punto de reorden
    activo             BOOLEAN       NOT NULL DEFAULT TRUE,
    creado_en          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    modificado_en      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- Índice para búsqueda por nombre (operaciones frecuentes en inventario)
CREATE INDEX IF NOT EXISTS idx_producto_nombre     ON producto USING GIN (nombre gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_producto_categoria  ON producto (id_categoria);
CREATE INDEX IF NOT EXISTS idx_producto_marca      ON producto (id_marca);
CREATE INDEX IF NOT EXISTS idx_producto_vencimiento ON producto (fecha_vencimiento)
    WHERE fecha_vencimiento IS NOT NULL;

COMMENT ON TABLE producto IS
  'Catálogo maestro de todos los SKUs activos e históricos de Fertilisa S.A.';
COMMENT ON COLUMN producto.codigo_producto IS
  'Código natural del sistema, limpiado.';
COMMENT ON COLUMN producto.codigo_estado_lote IS
  'Código de estado del lote tal como aparece en la hoja.';


-- --------------------------------------------------------------------------------------------------------------------------------
--  4.2 STOCK_SISTEMA — Saldo de inventario según el sistema ERP David
--  Representa el saldo oficial registrado antes de cada toma física.
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stock_sistema (
    id_stock           SERIAL        PRIMARY KEY,
    id_producto        INT           NOT NULL REFERENCES producto(id_producto),
    id_bodega          SMALLINT      NOT NULL REFERENCES bodega(id_bodega),
    fecha_saldo        DATE          NOT NULL,                               -- Fecha a la que corresponde el saldo
    cantidad_sistema   NUMERIC(12,2) NOT NULL DEFAULT 0                      -- Saldo según el sistema David
                       CHECK (cantidad_sistema >= 0),
    fuente             VARCHAR(30)   NOT NULL DEFAULT 'Sistema David',       -- Origen del dato
    creado_en          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    modificado_en      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    -- Un producto puede tener solo un saldo por bodega por fecha
    UNIQUE (id_producto, id_bodega, fecha_saldo)
);

CREATE INDEX IF NOT EXISTS idx_stock_sistema_fecha ON stock_sistema (fecha_saldo, id_producto);

COMMENT ON TABLE stock_sistema IS
  'Saldo de inventario según el sistema ERP David por producto, bodega y fecha. Fuente del campo "Sist. David" del Excel.';


-- --------------------------------------------------------------------------------------------------------------------------------
--  4.3 TOMA_FISICA — Encabezado de cada evento de auditoría de inventario
--  Un evento de toma física es la sesión completa de conteo (puede durar días).
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS toma_fisica (
    id_toma            SERIAL        PRIMARY KEY,
    codigo_toma        VARCHAR(20)   NOT NULL UNIQUE,                        -- Código identificador (TF-2026-05, TF-2026-06…)
    fecha_inicio       DATE          NOT NULL,
    fecha_fin          DATE,                                                 -- NULL si aún no ha concluido
    responsable        VARCHAR(120)  NOT NULL,                               -- Nombre del operario a cargo
    aprobado_por       VARCHAR(120),                                         -- Nombre del supervisor que aprueba el resultado
    estado             VARCHAR(15)   NOT NULL DEFAULT 'En Proceso'
                       CHECK (estado IN ('Planificada','En Proceso','Completada','Cancelada')),
    observaciones      TEXT,
    creado_en          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    modificado_en      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE toma_fisica IS
  'Encabezado de cada sesión de toma física de inventario. Una toma física puede abarcar varios días.';


-- --------------------------------------------------------------------------------------------------------------------------------
--  4.4 DETALLE_TOMA_FISICA — Conteo físico por producto en cada toma
--  Granularidad: 1 fila = 1 producto × 1 toma física × 1 bodega.
--  Es la tabla central que alimenta el modelo dimensional.
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS detalle_toma_fisica (
    id_detalle         SERIAL        PRIMARY KEY,
    id_toma            INT           NOT NULL REFERENCES toma_fisica(id_toma),
    id_producto        INT           NOT NULL REFERENCES producto(id_producto),
    id_bodega          SMALLINT      NOT NULL REFERENCES bodega(id_bodega),
    cantidad_fisica    NUMERIC(12,2) NOT NULL DEFAULT 0                      -- Unidades contadas manualmente
                       CHECK (cantidad_fisica >= 0),
    cantidad_sistema   NUMERIC(12,2) NOT NULL DEFAULT 0                      -- Saldo del sistema al momento de la toma
                       CHECK (cantidad_sistema >= 0),
    -- La diferencia se calcula siempre como física - sistema
    diferencia         NUMERIC(12,2) GENERATED ALWAYS AS
                       (cantidad_fisica - cantidad_sistema) STORED,
    id_tipo_disc       SMALLINT      REFERENCES tipo_discrepancia(id_tipo_disc), -- NULL si no hay discrepancia
    observacion        VARCHAR(500),                                         -- Texto libre de la observación operacional
    contado_por        VARCHAR(120),                                         -- Operario que realizó el conteo
    revisado           BOOLEAN       NOT NULL DEFAULT FALSE,                 -- TRUE = el jefe de bodega revisó este ítem
    creado_en          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    modificado_en      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    -- Un producto aparece solo una vez por toma física y bodega
    UNIQUE (id_toma, id_producto, id_bodega)
);

CREATE INDEX IF NOT EXISTS idx_dtf_toma      ON detalle_toma_fisica (id_toma);
CREATE INDEX IF NOT EXISTS idx_dtf_producto  ON detalle_toma_fisica (id_producto);
-- Índice parcial para consultas de discrepancias (caso frecuente en análisis BI)
CREATE INDEX IF NOT EXISTS idx_dtf_diferencia ON detalle_toma_fisica (id_toma)
    WHERE diferencia <> 0;

COMMENT ON TABLE detalle_toma_fisica IS
  'Línea de conteo físico por producto en una toma física. Fuente primaria para el ETL hacia el DWH.';
COMMENT ON COLUMN detalle_toma_fisica.diferencia IS
  'Columna generada: cantidad_fisica - cantidad_sistema. Positivo = sobrante; Negativo = faltante.';


-- --------------------------------------------------------------------------------------------------------------------------------
--  4.5 MOVIMIENTO_INVENTARIO — Registro de cada transacción de entrada/salida/ajuste
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS movimiento_inventario (
    id_movimiento      SERIAL        PRIMARY KEY,
    id_producto        INT           NOT NULL REFERENCES producto(id_producto),
    id_bodega          SMALLINT      NOT NULL REFERENCES bodega(id_bodega),
    id_tipo_mov        SMALLINT      NOT NULL REFERENCES tipo_movimiento(id_tipo_mov),
    fecha_movimiento   DATE          NOT NULL,
    cantidad           NUMERIC(12,2) NOT NULL
                       CHECK (cantidad > 0),                                 -- Siempre positivo; el tipo_movimiento define si suma o resta
    numero_documento   VARCHAR(50),                                          -- Número de factura, orden, ajuste, etc.
    referencia_toma    INT           REFERENCES toma_fisica(id_toma),        -- Vinculación al evento de toma física (si aplica)
    usuario_registro   VARCHAR(100)  NOT NULL DEFAULT current_user,
    observacion        VARCHAR(500),
    creado_en          TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_mov_producto ON movimiento_inventario (id_producto, fecha_movimiento DESC);
CREATE INDEX IF NOT EXISTS idx_mov_fecha    ON movimiento_inventario (fecha_movimiento DESC);

COMMENT ON TABLE movimiento_inventario IS
  'Registro de cada transacción que afecta el saldo de inventario: entradas, salidas, ajustes y devoluciones.';


-- ================================================================================================================================
--  SECCIÓN 5: TABLAS DE STAGING (CARGA DESDE ARCHIVOS CSV / EXCEL)
--  Estas tablas son la zona de aterrizaje de los archivos exportados.
--  EasyMorph o cualquier proceso externo vuelca los datos aquí en crudo,
--  y los procedimientos ETL leen de estas tablas para limpiar y cargar.
-- ================================================================================================================================

-- --------------------------------------------------------------------------------------------------------------------------------
--  5.1 STG_CARGA — Encabezado de cada proceso de carga de archivo
--  Registra metadatos del archivo importado: nombre, tamaño, hash MD5,
--  fecha y resultado final de la carga.
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stg_carga (
    id_carga         SERIAL        PRIMARY KEY,
    nombre_archivo   VARCHAR(300)  NOT NULL,                                 -- Nombre original del archivo (ej. Resumen.xlsx)
    hoja             VARCHAR(100),                                           -- Nombre de la hoja dentro del Excel (si aplica)
    ruta_archivo     TEXT,                                                   -- Ruta completa en el servidor / bucket
    hash_md5         VARCHAR(32),                                            -- MD5 del archivo para detectar duplicados
    total_filas_raw  INT,                                                    -- Total de filas leídas del archivo sin filtrar
    filas_validas    INT,                                                    -- Filas que superaron las validaciones básicas
    filas_rechazadas INT,                                                    -- Filas descartadas por errores de calidad
    estado           VARCHAR(15)   NOT NULL DEFAULT 'Iniciado'
                     CHECK (estado IN ('Iniciado','En Proceso','Completado','Error','Rechazado')),
    mensaje_error    TEXT,                                                   -- Detalle del error si estado = 'Error'
    usuario_carga    VARCHAR(100)  NOT NULL DEFAULT current_user,
    inicio_carga     TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    fin_carga        TIMESTAMPTZ,                                            -- Se actualiza al terminar el proceso
    observaciones    TEXT
);

COMMENT ON TABLE stg_carga IS
  'Encabezado de cada proceso de importación de archivo. Permite rastrear qué archivo originó cada carga.';
COMMENT ON COLUMN stg_carga.hash_md5 IS
  'Hash MD5 del archivo binario. Si ya existe un registro con el mismo hash, el proceso puede detectar duplicados.';


-- --------------------------------------------------------------------------------------------------------------------------------
--  5.2 STG_INVENTARIO_RAW — Datos crudos de la hoja "Fertilisa"
--  Todos los campos son VARCHAR para aceptar cualquier valor del Excel
--  sin rechazos por tipo. La limpieza ocurre en el ETL.
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stg_inventario_raw (
    id_stg_inv       SERIAL        PRIMARY KEY,
    id_carga         INT           NOT NULL REFERENCES stg_carga(id_carga), -- Vinculación al encabezado de carga
    fila_origen      INT,                                                    -- Número de fila en el archivo Excel (para trazabilidad)
    hoja_origen      VARCHAR(60)   NOT NULL DEFAULT 'Fertilisa',

    -- Columnas tal como vienen del archivo (nombres en crudo, sin normalizar)
    codigo_raw       VARCHAR(60),                                            -- Col B: código con posible apóstrofe ('4000100372)
    nombre_raw       VARCHAR(300),                                           -- Col C: nombre completo del producto
    fisico_raw       VARCHAR(30),                                            -- Col D: stock físico (puede venir como texto)
    sistema_raw      VARCHAR(30),                                            -- Col E: saldo sistema David
    diferencia_raw   VARCHAR(30),                                            -- Col F: diferencia (puede tener signos o texto)
    observacion_raw  VARCHAR(600),                                           -- Col G: observaciones de texto libre
    categoria_raw    VARCHAR(120),                                           -- Asignada en EasyMorph mediante fill-down de filas de sección

    -- Campos de control de calidad del staging
    procesado        BOOLEAN       NOT NULL DEFAULT FALSE,                   -- TRUE una vez que el ETL lo leyó y procesó
    valido           BOOLEAN,                                                -- TRUE si pasó todas las validaciones; FALSE si fue rechazado; NULL = pendiente
    motivo_rechazo   VARCHAR(300),                                           -- Descripción del motivo si valido = FALSE
    fecha_procesado  TIMESTAMPTZ,                                            -- Cuándo fue procesado por el ETL
    creado_en        TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_stg_inv_carga     ON stg_inventario_raw (id_carga);
CREATE INDEX IF NOT EXISTS idx_stg_inv_procesado ON stg_inventario_raw (procesado, valido);

COMMENT ON TABLE stg_inventario_raw IS
  'Zona de aterrizaje de la hoja "Fertilisa" del archivo Resumen.xlsx. '
  'Todos los tipos son VARCHAR para evitar errores de parsing. '
  'El ETL limpia y mueve los datos a las tablas operacionales.';


-- --------------------------------------------------------------------------------------------------------------------------------
--  5.3 STG_MANVERT_JIFFY_RAW — Datos crudos de la hoja "Manvert, Jiffy"
--  Esta hoja tiene columnas adicionales: Estado de lote, Fecha de Vencimiento
--  y Días de almacenaje, que no existen en la hoja principal.
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stg_manvert_jiffy_raw (
    id_stg_mj        SERIAL        PRIMARY KEY,
    id_carga         INT           NOT NULL REFERENCES stg_carga(id_carga),
    fila_origen      INT,
    hoja_origen      VARCHAR(60)   NOT NULL DEFAULT 'Manvert_Jiffy',

    -- Columnas propias de esta hoja
    lote_raw         VARCHAR(30),                                            -- Col A: número de lote (1483, 1358, 1086…)
    codigo_raw       VARCHAR(60),                                            -- Col B: código del producto
    nombre_raw       VARCHAR(300),                                           -- Col C: nombre del material
    estado_lote_raw  VARCHAR(20),                                            -- Col D: código de estado del lote (569, 905, 1239…)
    fisico_raw       VARCHAR(30),                                            -- Col E
    sistema_raw      VARCHAR(30),                                            -- Col F
    diferencia_raw   VARCHAR(30),                                            -- Col G
    observacion_raw  VARCHAR(600),                                           -- Col H
    fecha_venc_raw   VARCHAR(50),                                            -- Col I: fecha de vencimiento como texto
    almacenaje_raw   VARCHAR(20),                                            -- Col J: días de almacenaje permitidos

    -- Control de calidad
    procesado        BOOLEAN       NOT NULL DEFAULT FALSE,
    valido           BOOLEAN,
    motivo_rechazo   VARCHAR(300),
    fecha_procesado  TIMESTAMPTZ,
    creado_en        TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_stg_mj_carga     ON stg_manvert_jiffy_raw (id_carga);
CREATE INDEX IF NOT EXISTS idx_stg_mj_procesado ON stg_manvert_jiffy_raw (procesado, valido);

COMMENT ON TABLE stg_manvert_jiffy_raw IS
  'Zona de aterrizaje de la hoja "Manvert, Jiffy" del archivo Resumen.xlsx. '
  'Incluye campos de lote, estado de lote, fecha de vencimiento y días de almacenaje '
  'que no existen en la hoja Fertilisa.';


-- --------------------------------------------------------------------------------------------------------------------------------
--  5.4 STG_ERROR_LOG — Registro detallado de errores de validación por fila
--  Cuando el ETL rechaza una fila de staging, registra aquí el motivo
--  para facilitar la corrección y la re-carga.
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stg_error_log (
    id_error         SERIAL        PRIMARY KEY,
    id_carga         INT           NOT NULL REFERENCES stg_carga(id_carga),
    tabla_staging    VARCHAR(60)   NOT NULL,                                 -- 'stg_inventario_raw' o 'stg_manvert_jiffy_raw'
    id_fila_staging  INT           NOT NULL,                                 -- FK al id de la tabla de staging correspondiente
    fila_origen      INT,                                                    -- Número de fila en el archivo Excel
    campo_erroneo    VARCHAR(60),                                            -- Nombre del campo que falló la validación
    valor_recibido   TEXT,                                                   -- Valor problemático tal como llegó
    regla_violada    VARCHAR(100),                                           -- Nombre de la regla de validación (RT-01, formato_fecha, etc.)
    descripcion      TEXT,                                                   -- Descripción legible del error
    severidad        VARCHAR(10)   NOT NULL DEFAULT 'ERROR'
                     CHECK (severidad IN ('ERROR','WARNING','INFO')),
    creado_en        TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_stg_err_carga ON stg_error_log (id_carga);

COMMENT ON TABLE stg_error_log IS
  'Bitácora de errores de validación detectados durante el ETL por cada fila de staging. '
  'Permite corregir el archivo fuente y recargar solo las filas fallidas.';


-- ================================================================================================================================
--  SECCIÓN 6: FUNCIÓN Y TRIGGERS DE AUDITORÍA
--  Un único trigger genérico registra cambios en audit_log para cualquier tabla.
-- ================================================================================================================================

-- --------------------------------------------------------------------------------------------------------------------------------
--  6.1 fn_audit_trigger — Función genérica de auditoría
--  Se invoca desde los triggers de AFTER INSERT/UPDATE/DELETE en cada tabla.
--  Captura el estado anterior y posterior del registro como JSONB.
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_audit_trigger()
RETURNS TRIGGER AS $$
DECLARE
    v_id_registro TEXT;
    v_antes       JSONB;
    v_despues     JSONB;
BEGIN
    -- Determinar el identificador del registro según la operación
    IF TG_OP = 'DELETE' THEN
        v_id_registro := (row_to_json(OLD))::JSONB ->> 'id';   -- Intentar extraer campo "id"
        v_antes       := row_to_json(OLD)::JSONB;
        v_despues     := NULL;
    ELSIF TG_OP = 'INSERT' THEN
        v_id_registro := (row_to_json(NEW))::JSONB ->> 'id';
        v_antes       := NULL;
        v_despues     := row_to_json(NEW)::JSONB;
    ELSE  -- UPDATE
        v_id_registro := (row_to_json(NEW))::JSONB ->> 'id';
        v_antes       := row_to_json(OLD)::JSONB;
        v_despues     := row_to_json(NEW)::JSONB;
    END IF;

    INSERT INTO audit_log (
        esquema, tabla, operacion,
        id_registro, valores_antes, valores_despues,
        usuario_db, timestamp_utc
    ) VALUES (
        TG_TABLE_SCHEMA,    -- Schema de la tabla que disparó el trigger
        TG_TABLE_NAME,      -- Nombre de la tabla
        TG_OP,              -- 'INSERT', 'UPDATE' o 'DELETE'
        v_id_registro,
        v_antes,
        v_despues,
        current_user,
        NOW()
    );

    -- Para triggers BEFORE, retornar NEW/OLD según corresponda
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION fn_audit_trigger IS
  'Función genérica de auditoría. Escribe en audit_log el estado anterior y posterior de cada registro '
  'modificado. Se asocia mediante triggers AFTER INSERT/UPDATE/DELETE en las tablas del schema.';


-- --------------------------------------------------------------------------------------------------------------------------------
--  6.2 Función auxiliar: actualizar modificado_en automáticamente
-- --------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_set_modificado_en()
RETURNS TRIGGER AS $$
BEGIN
    NEW.modificado_en := NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- --------------------------------------------------------------------------------------------------------------------------------
--  6.3 Aplicar triggers a las tablas principales
-- --------------------------------------------------------------------------------------------------------------------------------

-- Trigger de auditoría en PRODUCTO
CREATE TRIGGER trg_audit_producto
    AFTER INSERT OR UPDATE OR DELETE ON producto
    FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- Trigger para actualizar modificado_en en PRODUCTO
CREATE TRIGGER trg_mod_producto
    BEFORE UPDATE ON producto
    FOR EACH ROW EXECUTE FUNCTION fn_set_modificado_en();


-- Trigger de auditoría en DETALLE_TOMA_FISICA (tabla más crítica operacionalmente)
CREATE TRIGGER trg_audit_detalle_toma
    AFTER INSERT OR UPDATE OR DELETE ON detalle_toma_fisica
    FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

CREATE TRIGGER trg_mod_detalle_toma
    BEFORE UPDATE ON detalle_toma_fisica
    FOR EACH ROW EXECUTE FUNCTION fn_set_modificado_en();


-- Trigger de auditoría en STOCK_SISTEMA
CREATE TRIGGER trg_audit_stock_sistema
    AFTER INSERT OR UPDATE OR DELETE ON stock_sistema
    FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

CREATE TRIGGER trg_mod_stock_sistema
    BEFORE UPDATE ON stock_sistema
    FOR EACH ROW EXECUTE FUNCTION fn_set_modificado_en();


-- Trigger de auditoría en TOMA_FISICA
CREATE TRIGGER trg_audit_toma_fisica
    AFTER INSERT OR UPDATE OR DELETE ON toma_fisica
    FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

CREATE TRIGGER trg_mod_toma_fisica
    BEFORE UPDATE ON toma_fisica
    FOR EACH ROW EXECUTE FUNCTION fn_set_modificado_en();


-- Trigger de auditoría en MOVIMIENTO_INVENTARIO (INSERT only; los movimientos no se modifican)
CREATE TRIGGER trg_audit_movimiento
    AFTER INSERT ON movimiento_inventario
    FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();


-- ================================================================================================================================
--  SECCIÓN 7: ÍNDICES OPERACIONALES ADICIONALES
-- ================================================================================================================================

-- Índice compuesto para consultas de saldo actual por bodega
CREATE INDEX IF NOT EXISTS idx_stock_prod_bodega
    ON stock_sistema (id_producto, id_bodega, fecha_saldo DESC);

-- Índice para consultas de movimientos por producto y fecha 
CREATE INDEX IF NOT EXISTS idx_mov_prod_fecha
    ON movimiento_inventario (id_producto, fecha_movimiento DESC);

-- Índice GIN sobre observaciones de toma física para búsquedas de texto
CREATE INDEX IF NOT EXISTS idx_dtf_obs_trgm
    ON detalle_toma_fisica USING GIN (observacion gin_trgm_ops);


