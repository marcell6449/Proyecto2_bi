"""
================================================================================
  ARCHIVO   : etl_landing.py
  PROYECTO  : Sistema de Gestión de Inventario — Fertilisa S.A.
  MÓDULO    : ETL Capa 0 — Excel → fertiliza_landing
  VERSIÓN   : 2.0 — Mayo 2026

  DESCRIPCIÓN:
    Lee todos los archivos .xlsx de una carpeta y los carga en el schema
    fertiliza_landing de PostgreSQL aplicando las reglas RL-01 a RL-10
    documentadas en reglas_consolidadas_fertilisa.md v2.0

  ESTRUCTURA REAL DEL ARCHIVO Resumen.xlsx (verificada sobre el archivo fuente):
    Hoja "Fertilisa":
      - Columna A (idx 0): siempre vacía
      - Columna B (idx 1): código del producto (con apóstrofe líder) O nombre de sección
      - Columna C (idx 2): nombre del producto (o texto decorativo en filas de sección)
      - Columna D (idx 3): cantidad física (entero)
      - Columna E (idx 4): cantidad sistema David (entero o None)
      - Columna F (idx 5): diferencia (entero)
      - Columna G (idx 6): observaciones (texto libre o None)
      Filas especiales:
        - Fila 4  : sección "Granular - Solubles"   (col B)
        - Fila 5  : encabezado de columnas           (col B = "Codigo")
        - Fila 113: sección "Liquidos"               (col B)
        - Fila 114: encabezado de columnas repetido
        - Fila 195: sección "Material para Invernaderos - Sustrato y Otros" (col B)
        - Fila 196: encabezado de columnas repetido
        Patrón: la sección está en col B, NO en col C

    Hoja "Manvert, Jiffy":
      - Columna A  (idx 0) : número de lote (entero o None)
      - Columna B  (idx 1) : código (con apóstrofe)
      - Columna C  (idx 2) : nombre del material
      - Columna D  (idx 3) : estado del lote (569, 905, 1239, 'N/A')
      - Columna E  (idx 4) : cantidad física
      - Columna F  (idx 5) : cantidad sistema
      - Columna G  (idx 6) : diferencia
      - Columna H  (idx 7) : observaciones
      - Columna I  (idx 8) : fecha vencimiento (datetime o 'N/A')
      - Columna J  (idx 9) : SIEMPRE '#REF!' — fórmula rota, IGNORAR
      - Columna K  (idx 10): None en todas las filas
      - Columna L  (idx 11): días de almacenaje (entero o None)
      Fila 4: encabezado de columnas (col B = "Codigo")
      Datos desde fila 5 en adelante

  USO:
    python etl_landing.py --input-dir /ruta/carpeta [--log-dir ./logs] [--usuario nombre]

  DEPENDENCIAS:
    pip install openpyxl psycopg2-binary python-dotenv

  VARIABLES DE ENTORNO (.env):
    DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD
================================================================================
"""

import argparse
import hashlib
import logging
import os
import re
import sys
from datetime import datetime, date
from pathlib import Path
from typing import Optional, Tuple

import openpyxl
import psycopg2
import psycopg2.extras
from dotenv import load_dotenv


# ─────────────────────────────────────────────────────────────────────────────
#  CONSTANTES — basadas en la estructura real del archivo
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_VERSION = "2.0.0"

# Hojas conocidas y su tipo interno
HOJAS_CONOCIDAS = {
    "Fertilisa":      "fertilisa",
    "Manvert, Jiffy": "manvert_jiffy",
    "Manvert,Jiffy":  "manvert_jiffy",
    "Manvert Jiffy":  "manvert_jiffy",
}

# Nombres exactos de sección en col B de la hoja Fertilisa (RL-04)
# Verificados directamente sobre el archivo fuente
NOMBRES_SECCION = {
    "granular - solubles":                              "Granular - Solubles",
    "granular-solubles":                                "Granular - Solubles",
    "liquidos":                                         "Liquidos",
    "líquidos":                                         "Liquidos",
    "material para invernaderos - sustrato y otros":    "Material para Invernaderos - Sustrato y Otros",
    "material para invernaderos":                       "Material para Invernaderos - Sustrato y Otros",
}

# Valores que identifican una fila de encabezado de columnas (RL-07)
VALORES_ENCABEZADO = {"codigo", "código", "cod", "code"}

# Valor que indica fórmula rota en Manvert col J — debe ignorarse siempre
VALOR_REF_ROTO = "#REF!"

# Índices de columna reales (base 0) — verificados sobre el archivo
class ColFertilisa:
    A         = 0   # siempre vacía
    CODIGO    = 1   # B: código o nombre de sección
    NOMBRE    = 2   # C: nombre del producto
    FISICO    = 3   # D: cantidad física
    SISTEMA   = 4   # E: saldo Sistema David
    DIFERENCIA = 5  # F: diferencia
    OBSERVACION = 6 # G: observaciones

class ColManvert:
    LOTE       = 0   # A: número de lote (o None)
    CODIGO     = 1   # B: código del producto
    NOMBRE     = 2   # C: nombre del material
    ESTADO     = 3   # D: estado del lote
    FISICO     = 4   # E: cantidad física
    SISTEMA    = 5   # F: saldo sistema
    DIFERENCIA = 6   # G: diferencia
    OBSERVACION = 7  # H: observaciones
    FECHA_VENC  = 8  # I: fecha de vencimiento (datetime o 'N/A')
    # Columna J (idx 9) = '#REF!' — SIEMPRE IGNORAR
    # Columna K (idx 10) = None   — SIEMPRE IGNORAR
    ALMACENAJE  = 11 # L: días de almacenaje (entero o None)


# ─────────────────────────────────────────────────────────────────────────────
#  CONFIGURACIÓN DE LOGGING  (RB-07)
# ─────────────────────────────────────────────────────────────────────────────

def configurar_logging(log_dir: Optional[str]) -> logging.Logger:
    logger = logging.getLogger("etl_landing")
    logger.setLevel(logging.DEBUG)
    fmt = logging.Formatter(
        fmt="%(asctime)s | %(levelname)-8s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S"
    )

    # Consola: INFO y superior
    ch = logging.StreamHandler(sys.stdout)
    ch.setLevel(logging.INFO)
    ch.setFormatter(fmt)
    logger.addHandler(ch)

    # Archivo: DEBUG y superior
    if log_dir:
        Path(log_dir).mkdir(parents=True, exist_ok=True)
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        log_path = Path(log_dir) / f"etl_landing_{ts}.log"
        fh = logging.FileHandler(log_path, encoding="utf-8")
        fh.setLevel(logging.DEBUG)
        fh.setFormatter(fmt)
        logger.addHandler(fh)
        logger.info(f"Log de archivo: {log_path}")

    return logger


# ─────────────────────────────────────────────────────────────────────────────
#  CONEXIÓN A BASE DE DATOS  (RB-02)
# ─────────────────────────────────────────────────────────────────────────────

def conectar_db(logger: logging.Logger) -> psycopg2.extensions.connection:
    load_dotenv()
    params = {
    "host":     os.getenv("DB_HOST"),
    "port":     os.getenv("DB_PORT", "5432"),
    "dbname":   os.getenv("DB_NAME"),
    "user":     os.getenv("DB_USER"),
    "password": os.getenv("DB_PASSWORD"),
    "sslmode":  os.getenv("DB_SSLMODE", "prefer"),  # ← agregar esta línea
}
    try:
        conn = psycopg2.connect(**params)
        conn.autocommit = False
        logger.info(
            f"Conectado a PostgreSQL: "
            f"{params['host']}:{params['port']}/{params['dbname']}"
        )
        return conn
    except psycopg2.OperationalError as e:
        logger.critical(f"ERROR DE CONEXIÓN: {e}")
        logger.critical("Proceso detenido. Verificar credenciales y disponibilidad del servidor.")
        sys.exit(1)


# ─────────────────────────────────────────────────────────────────────────────
#  UTILIDADES DE LIMPIEZA  (Reglas RL-*)
# ─────────────────────────────────────────────────────────────────────────────

def celda_a_str(valor) -> Optional[str]:
    """
    RL-03: Convierte cualquier valor de celda a string para almacenamiento en VARCHAR.
    - datetime → ISO string 'YYYY-MM-DD'
    - None     → None (NULL en BD)
    - número   → str() sin notación científica
    - texto    → strip(), None si queda vacío
    """
    if valor is None:
        return None
    if isinstance(valor, (datetime, date)):
        return valor.strftime("%Y-%m-%d")
    texto = str(valor).strip()
    return texto if texto else None


def limpiar_codigo(valor_raw: Optional[str]) -> Optional[str]:
    """
    RL-01: Remueve el apóstrofe líder que Excel agrega para forzar formato texto.
    Aplica además strip() (RL-02 aplicado a códigos).
    """
    if not valor_raw:
        return None
    limpio = str(valor_raw).lstrip("'").strip()
    return limpio if limpio else None


def limpiar_nombre(valor_raw: Optional[str]) -> Optional[str]:
    """
    RL-02: Colapsa espacios múltiples internos y aplica strip().
    No modifica capitalización.
    """
    if not valor_raw:
        return None
    limpio = re.sub(r" +", " ", str(valor_raw).strip())
    return limpio if limpio else None


def es_numerico(valor_raw: Optional[str]) -> bool:
    """
    Verifica si un campo _raw puede convertirse a número.
    Acepta enteros y decimales con coma o punto.
    """
    if not valor_raw:
        return False
    try:
        float(str(valor_raw).replace(",", "").strip())
        return True
    except ValueError:
        return False


def es_fecha_parseable(valor_raw: Optional[str]) -> bool:
    """
    RL-09: Verifica si un campo de fecha puede ser parseado.
    None y 'N/A' son válidos (significa que no aplica).
    """
    if not valor_raw:
        return True
    if valor_raw.upper() in ("N/A", "NA", "NONE", ""):
        return True
    for fmt in ("%Y-%m-%d", "%Y-%m-%dT%H:%M:%S", "%d/%m/%Y", "%m/%d/%Y", "%d-%m-%Y"):
        try:
            datetime.strptime(valor_raw[:10], fmt)
            return True
        except ValueError:
            continue
    return False


def detectar_seccion_fertilisa(col_b_raw: Optional[str]) -> Optional[str]:
    """
    RL-04: Detecta si el valor de la columna B es un nombre de sección.
    En la hoja Fertilisa, la sección está SIEMPRE en col B (no en col C).
    Retorna el nombre canónico de la sección o None si no es sección.
    """
    if not col_b_raw:
        return None
    normalizado = str(col_b_raw).strip().lower()
    return NOMBRES_SECCION.get(normalizado)


def es_encabezado_columnas(col_b_raw: Optional[str]) -> bool:
    """
    RL-07: Detecta la fila de encabezado de columnas repetida.
    En Fertilisa y Manvert aparece como col B = 'Codigo'.
    """
    if not col_b_raw:
        return False
    limpio = limpiar_codigo(col_b_raw)
    return bool(limpio) and limpio.lower() in VALORES_ENCABEZADO


def es_fila_vacia_fertilisa(row: tuple) -> bool:
    """
    RL-06: Fila vacía si código, nombre, físico y sistema son todos None o vacíos.
    """
    campos = [
        celda_a_str(row[ColFertilisa.CODIGO]   if len(row) > ColFertilisa.CODIGO   else None),
        celda_a_str(row[ColFertilisa.NOMBRE]    if len(row) > ColFertilisa.NOMBRE    else None),
        celda_a_str(row[ColFertilisa.FISICO]    if len(row) > ColFertilisa.FISICO    else None),
        celda_a_str(row[ColFertilisa.SISTEMA]   if len(row) > ColFertilisa.SISTEMA   else None),
    ]
    return not any(campos)


def es_fila_vacia_manvert(row: tuple) -> bool:
    """RL-06 para Manvert: vacía si código, nombre, físico y sistema son None."""
    campos = [
        celda_a_str(row[ColManvert.CODIGO]  if len(row) > ColManvert.CODIGO  else None),
        celda_a_str(row[ColManvert.NOMBRE]  if len(row) > ColManvert.NOMBRE  else None),
        celda_a_str(row[ColManvert.FISICO]  if len(row) > ColManvert.FISICO  else None),
        celda_a_str(row[ColManvert.SISTEMA] if len(row) > ColManvert.SISTEMA else None),
    ]
    return not any(campos)


def calcular_flags_fertilisa(codigo_raw, nombre_raw, fisico_raw, sistema_raw) -> dict:
    """
    Calcula los flags lnd_* para una fila de lnd_fertilisa_raw.
    Revisión superficial; la validación profunda ocurre en el staging del OLTP.
    """
    tiene_codigo    = bool(limpiar_codigo(codigo_raw))
    tiene_nombre    = bool(limpiar_nombre(nombre_raw))
    fisico_num      = es_numerico(fisico_raw)
    sistema_num     = es_numerico(sistema_raw)
    # Lista para pasar es suficiente tener código + nombre + físico numérico (RV-04: sistema vacío no bloquea)
    listo           = tiene_codigo and tiene_nombre and fisico_num
    return {
        "lnd_tiene_codigo":     tiene_codigo,
        "lnd_tiene_nombre":     tiene_nombre,
        "lnd_fisico_numerico":  fisico_num,
        "lnd_sistema_numerico": sistema_num,
        "lnd_listo_para_stg":   listo,
    }


def calcular_flags_manvert(codigo_raw, nombre_raw, fisico_raw, sistema_raw,
                           fecha_venc_raw, almacenaje_raw) -> dict:
    """Calcula los flags lnd_* para una fila de lnd_manvert_jiffy_raw."""
    tiene_codigo    = bool(limpiar_codigo(codigo_raw))
    tiene_nombre    = bool(limpiar_nombre(nombre_raw))
    fisico_num      = es_numerico(fisico_raw)
    sistema_num     = es_numerico(sistema_raw)
    fecha_parseable = es_fecha_parseable(fecha_venc_raw)
    almac_num       = es_numerico(almacenaje_raw)
    listo           = tiene_codigo and tiene_nombre and fisico_num
    return {
        "lnd_tiene_codigo":          tiene_codigo,
        "lnd_tiene_nombre":          tiene_nombre,
        "lnd_fisico_numerico":       fisico_num,
        "lnd_sistema_numerico":      sistema_num,
        "lnd_fecha_venc_parseable":  fecha_parseable,
        "lnd_almacenaje_numerico":   almac_num,
        "lnd_listo_para_stg":        listo,
    }


def extraer_celda(row: tuple, idx: int) -> Optional[str]:
    """Extrae la celda en el índice dado y la convierte a string seguro."""
    return celda_a_str(row[idx] if len(row) > idx else None)


# ─────────────────────────────────────────────────────────────────────────────
#  CÁLCULO DE MD5  (RB-01)
# ─────────────────────────────────────────────────────────────────────────────

def calcular_md5(ruta: Path) -> str:
    h = hashlib.md5()
    with open(ruta, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


# ─────────────────────────────────────────────────────────────────────────────
#  OPERACIONES EN BASE DE DATOS
# ─────────────────────────────────────────────────────────────────────────────

def verificar_duplicado(cur, hash_md5: str, logger: logging.Logger) -> bool:
    """RB-01: Retorna True si el archivo ya fue procesado (mismo MD5)."""
    cur.execute("""
        SELECT id_archivo_log, nombre_archivo, inicio_proceso
        FROM fertiliza_landing.lnd_archivo_log
        WHERE hash_md5 = %s AND estado = 'Procesado'
        LIMIT 1
    """, (hash_md5,))
    row = cur.fetchone()
    if row:
        logger.warning(
            f"DUPLICADO — MD5 {hash_md5} ya procesado "
            f"(id={row[0]}, archivo='{row[1]}', fecha={row[2]}). Abortando."
        )
        return True
    return False


def registrar_archivo_log(cur, nombre, ruta, hash_md5, tamanio, usuario) -> int:
    cur.execute("""
        INSERT INTO fertiliza_landing.lnd_archivo_log
            (nombre_archivo, ruta_origen, hash_md5, tamanio_bytes,
             estado, ejecutado_por, script_version, inicio_proceso)
        VALUES (%s,%s,%s,%s,'En Proceso',%s,%s,NOW())
        RETURNING id_archivo_log
    """, (nombre, ruta, hash_md5, tamanio, usuario, SCRIPT_VERSION))
    return cur.fetchone()[0]


def actualizar_archivo_log(cur, id_archivo, estado, total_filas,
                           filas_insertadas, mensaje=None):
    cur.execute("""
        UPDATE fertiliza_landing.lnd_archivo_log
        SET estado=%s, total_filas_raw=%s, filas_insertadas=%s,
            mensaje=%s, fin_proceso=NOW()
        WHERE id_archivo_log=%s
    """, (estado, total_filas, filas_insertadas, mensaje, id_archivo))


def registrar_carga(cur, id_archivo, hoja, periodo, usuario) -> int:
    cur.execute("""
        INSERT INTO fertiliza_landing.lnd_carga
            (id_archivo_log, hoja_procesada, periodo_datos,
             estado, ejecutado_por, inicio_carga)
        VALUES (%s,%s,%s,'Iniciado',%s,NOW())
        RETURNING id_carga
    """, (id_archivo, hoja, periodo, usuario))
    return cur.fetchone()[0]


def actualizar_carga(cur, id_carga, estado, leidas, vacias,
                     secciones, insertadas, mensaje=None):
    cur.execute("""
        UPDATE fertiliza_landing.lnd_carga
        SET estado=%s, filas_leidas=%s, filas_vacias=%s,
            filas_seccion=%s, filas_insertadas=%s,
            mensaje_error=%s, fin_carga=NOW()
        WHERE id_carga=%s
    """, (estado, leidas, vacias, secciones, insertadas, mensaje, id_carga))


# ─────────────────────────────────────────────────────────────────────────────
#  PROCESAMIENTO HOJA FERTILISA
# ─────────────────────────────────────────────────────────────────────────────

SQL_INSERT_FERTILISA = """
    INSERT INTO fertiliza_landing.lnd_fertilisa_raw (
        id_carga, fila_excel,
        col_a_raw, codigo_raw, nombre_raw,
        fisico_raw, sistema_raw, diferencia_raw, observacion_raw,
        categoria_raw, es_fila_seccion, es_fila_vacia,
        lnd_tiene_codigo, lnd_tiene_nombre,
        lnd_fisico_numerico, lnd_sistema_numerico,
        lnd_listo_para_stg
    ) VALUES %s
""" 


        
        
def procesar_hoja_fertilisa(ws, cur, id_carga, logger):
    cnt = {"leidas": 0, "vacias": 0, "secciones": 0, "encabezados": 0, "insertadas": 0, "warnings": 0}
    
    registros_a_insertar = []
    categoria_actual = None
    fila_excel = 3
    
    for row in ws.iter_rows(min_row=4, values_only=True): 
        cnt["leidas"] += 1
        fila_excel += 1
        
        # Extracción segura usando tu función de utilidad
        col_a_raw      = extraer_celda(row, ColFertilisa.A)
        codigo_raw     = extraer_celda(row, ColFertilisa.CODIGO)
        nombre_raw     = extraer_celda(row, ColFertilisa.NOMBRE)
        fisico_raw     = extraer_celda(row, ColFertilisa.FISICO)
        sistema_raw    = extraer_celda(row, ColFertilisa.SISTEMA)
        diferencia_raw = extraer_celda(row, ColFertilisa.DIFERENCIA)
        observacion_raw= extraer_celda(row, ColFertilisa.OBSERVACION)
        
        if es_fila_vacia_fertilisa(row):
            cnt["vacias"] += 1
            continue
            
        if es_encabezado_columnas(codigo_raw):
            cnt["encabezados"] += 1
            continue
            
        seccion_detectada = detectar_seccion_fertilisa(codigo_raw)
        if seccion_detectada:
            categoria_actual = seccion_detectada
            cnt["secciones"] += 1
            
            # Insertamos la fila de sección para mantener el registro, pero marcada
            registros_a_insertar.append((
                id_carga, fila_excel, col_a_raw, codigo_raw, nombre_raw,
                fisico_raw, sistema_raw, diferencia_raw, observacion_raw,
                categoria_actual, True, False,  # es_seccion, es_vacia
                False, False, False, False, False # flags lnd_* en falso
            ))
            continue
            
        # Calcular flags de calidad para datos normales
        flags = calcular_flags_fertilisa(codigo_raw, nombre_raw, fisico_raw, sistema_raw)
        
        registros_a_insertar.append((
            id_carga, fila_excel, col_a_raw, codigo_raw, nombre_raw,
            fisico_raw, sistema_raw, diferencia_raw, observacion_raw,
            categoria_actual, False, False, # es_seccion, es_vacia
            flags["lnd_tiene_codigo"], flags["lnd_tiene_nombre"],
            flags["lnd_fisico_numerico"], flags["lnd_sistema_numerico"],
            flags["lnd_listo_para_stg"]
        ))

    if registros_a_insertar:
        psycopg2.extras.execute_values(cur, SQL_INSERT_FERTILISA, registros_a_insertar)
        cnt["insertadas"] += len(registros_a_insertar)

    return cnt


# ─────────────────────────────────────────────────────────────────────────────
#  PROCESAMIENTO HOJA MANVERT, JIFFY
# ─────────────────────────────────────────────────────────────────────────────

SQL_INSERT_MANVERT = """
    INSERT INTO fertiliza_landing.lnd_manvert_jiffy_raw (
        id_carga, fila_excel,
        lote_raw, codigo_raw, nombre_raw, estado_lote_raw,
        fisico_raw, sistema_raw, diferencia_raw,
        observacion_raw, fecha_venc_raw, almacenaje_raw,
        es_fila_seccion, es_fila_vacia,
        lnd_tiene_codigo, lnd_tiene_nombre,
        lnd_fisico_numerico, lnd_sistema_numerico,
        lnd_fecha_venc_parseable, lnd_almacenaje_numerico,
        lnd_listo_para_stg
    ) VALUES %s
"""


def procesar_hoja_manvert_jiffy(ws, cur, id_carga, logger):
    cnt = {"leidas": 0, "vacias": 0, "secciones": 0, "encabezados": 0, "insertadas": 0, "warnings": 0}
    
    registros_a_insertar = []
    fila_excel = 3
    
    for row in ws.iter_rows(min_row=4, values_only=True):
        cnt["leidas"] += 1
        fila_excel += 1
        
        lote_raw        = extraer_celda(row, ColManvert.LOTE)
        codigo_raw      = extraer_celda(row, ColManvert.CODIGO)
        nombre_raw      = extraer_celda(row, ColManvert.NOMBRE)
        estado_lote_raw = extraer_celda(row, ColManvert.ESTADO)
        fisico_raw      = extraer_celda(row, ColManvert.FISICO)
        sistema_raw     = extraer_celda(row, ColManvert.SISTEMA)
        diferencia_raw  = extraer_celda(row, ColManvert.DIFERENCIA)
        observacion_raw = extraer_celda(row, ColManvert.OBSERVACION)
        fecha_venc_raw  = extraer_celda(row, ColManvert.FECHA_VENC)
        almacenaje_raw  = extraer_celda(row, ColManvert.ALMACENAJE)
        
        if es_fila_vacia_manvert(row):
            cnt["vacias"] += 1
            continue
            
        if es_encabezado_columnas(codigo_raw):
            cnt["encabezados"] += 1
            continue

        flags = calcular_flags_manvert(codigo_raw, nombre_raw, fisico_raw, sistema_raw, fecha_venc_raw, almacenaje_raw)
        
        registros_a_insertar.append((
            id_carga, fila_excel,
            lote_raw, codigo_raw, nombre_raw, estado_lote_raw,
            fisico_raw, sistema_raw, diferencia_raw,
            observacion_raw, fecha_venc_raw, almacenaje_raw,
            False, False, # es_seccion, es_vacia
            flags["lnd_tiene_codigo"], flags["lnd_tiene_nombre"],
            flags["lnd_fisico_numerico"], flags["lnd_sistema_numerico"],
            flags["lnd_fecha_venc_parseable"], flags["lnd_almacenaje_numerico"],
            flags["lnd_listo_para_stg"]
        ))
        
    if registros_a_insertar:
        psycopg2.extras.execute_values(cur, SQL_INSERT_MANVERT, registros_a_insertar)
        cnt["insertadas"] += len(registros_a_insertar)
        
    return cnt
# ─────────────────────────────────────────────────────────────────────────────
#  CHECKLIST PRE-CARGA  (Sección 8 del documento de reglas)
# ─────────────────────────────────────────────────────────────────────────────

def checklist_pre_carga(wb, nombre_archivo: str,
                         logger: logging.Logger) -> Tuple[bool, list]:
    """
    Ejecuta el checklist pre-carga antes de procesar cualquier fila.
    Retorna (continuar: bool, hojas_a_procesar: list).
    """
    hojas_a_procesar = []
    puede_continuar = True

    # Check 4: al menos una hoja conocida
    for nombre_hoja, tipo in HOJAS_CONOCIDAS.items():
        if nombre_hoja in wb.sheetnames:
            if tipo not in [t for _, t in hojas_a_procesar]:
                hojas_a_procesar.append((nombre_hoja, tipo))

    if not hojas_a_procesar:
        logger.warning(
            f"  [{nombre_archivo}] CHECK-4 FAIL: ninguna hoja conocida encontrada. "
            f"Hojas disponibles: {wb.sheetnames}"
        )
        puede_continuar = False

    # Check 5: hoja Fertilisa tiene al menos una sección conocida
    if "Fertilisa" in wb.sheetnames:
        ws = wb["Fertilisa"]
        secciones_encontradas = 0
        for row in ws.iter_rows(values_only=True):
            col_b = celda_a_str(row[ColFertilisa.CODIGO] if len(row) > ColFertilisa.CODIGO else None)
            if detectar_seccion_fertilisa(col_b):
                secciones_encontradas += 1
        if secciones_encontradas == 0:
            logger.warning(
                f"  [{nombre_archivo}] CHECK-5 WARNING: "
                f"no se encontraron filas de sección en 'Fertilisa'. "
                f"Posible cambio de formato en el archivo."
            )

    # Check 6: al menos 80% de filas tienen código no vacío
    if "Fertilisa" in wb.sheetnames:
        ws = wb["Fertilisa"]
        total_no_vacias = 0
        con_codigo = 0
        for row in ws.iter_rows(values_only=True):
            col_b = celda_a_str(row[ColFertilisa.CODIGO] if len(row) > ColFertilisa.CODIGO else None)
            if not es_fila_vacia_fertilisa(row) and not es_encabezado_columnas(col_b):
                nombre_sec = detectar_seccion_fertilisa(col_b)
                if not nombre_sec:
                    total_no_vacias += 1
                    if limpiar_codigo(col_b):
                        con_codigo += 1
        if total_no_vacias > 0:
            pct = (con_codigo / total_no_vacias) * 100
            if pct < 80:
                logger.warning(
                    f"  [{nombre_archivo}] CHECK-6 WARNING: "
                    f"solo {pct:.1f}% de filas tienen código. "
                    f"Posible archivo corrupto o mal exportado."
                )
            else:
                logger.info(
                    f"  [{nombre_archivo}] CHECK-6 OK: "
                    f"{pct:.1f}% de filas tienen código."
                )

    # Reportar hojas desconocidas (RB-04)
    for hoja in wb.sheetnames:
        if hoja not in HOJAS_CONOCIDAS:
            logger.warning(f"  [{nombre_archivo}] Hoja desconocida ignorada: '{hoja}'")

    # Reportar hojas conocidas ausentes (RB-05)
    hojas_procesadas_nombres = {h for h, _ in hojas_a_procesar}
    for nombre_esperado in ["Fertilisa", "Manvert, Jiffy"]:
        if nombre_esperado not in wb.sheetnames and nombre_esperado not in hojas_procesadas_nombres:
            logger.info(
                f"  [{nombre_archivo}] Hoja '{nombre_esperado}' no encontrada. "
                f"Se continúa con las hojas disponibles."
            )

    return puede_continuar, hojas_a_procesar


# ─────────────────────────────────────────────────────────────────────────────
#  PROCESAMIENTO DE UN ARCHIVO XLSX
# ─────────────────────────────────────────────────────────────────────────────

def procesar_archivo(ruta: Path, conn, logger: logging.Logger,
                     usuario: str) -> bool:
    """
    Procesa un único archivo .xlsx completo.
    Retorna True si exitoso, False si abortado o fallido.
    """
    logger.info(f"{'─' * 60}")
    logger.info(f"Archivo: {ruta.name}")

    tamanio  = ruta.stat().st_size
    hash_md5 = calcular_md5(ruta)
    logger.info(f"  MD5: {hash_md5} | Tamaño: {tamanio:,} bytes")

    cur = conn.cursor()

    # ── RB-01: verificar duplicado ────────────────────────────────────────────
    if verificar_duplicado(cur, hash_md5, logger):
        cur.close()
        return False

    # ── Registrar en lnd_archivo_log ──────────────────────────────────────────
    id_archivo = registrar_archivo_log(
        cur, ruta.name, str(ruta.resolve()), hash_md5, tamanio, usuario
    )
    conn.commit()
    logger.info(f"  Registrado en lnd_archivo_log (id={id_archivo})")

    # ── Abrir el workbook con data_only=True (resuelve fórmulas) ─────────────
    try:
        wb = openpyxl.load_workbook(ruta, read_only=False, data_only=True)
    except Exception as e:
        logger.error(f"  No se pudo abrir el Excel: {e}")
        actualizar_archivo_log(cur, id_archivo, "Error", 0, 0, str(e))
        conn.commit()
        cur.close()
        return False

    # ── Checklist pre-carga ───────────────────────────────────────────────────
    puede_continuar, hojas_a_procesar = checklist_pre_carga(wb, ruta.name, logger)
    if not puede_continuar:
        actualizar_archivo_log(cur, id_archivo, "Error", 0, 0,
                                "Checklist pre-carga fallido: sin hojas conocidas")
        conn.commit()
        wb.close()
        cur.close()
        return False

    # ── Inferir período de los datos ──────────────────────────────────────────
    periodo = datetime.now().strftime("%Y-%m")

    total_filas_global  = 0
    total_insert_global = 0
    alguna_ok           = False

    # ── Procesar cada hoja conocida ───────────────────────────────────────────
    for nombre_hoja, tipo_hoja in hojas_a_procesar:
        logger.info(f"  → Procesando hoja '{nombre_hoja}'")
        ws = wb[nombre_hoja]

        id_carga = registrar_carga(cur, id_archivo, nombre_hoja, periodo, usuario)
        conn.commit()

        try:
            if tipo_hoja == "fertilisa":
                cnt = procesar_hoja_fertilisa(ws, cur, id_carga, logger)
            else:
                cnt = procesar_hoja_manvert_jiffy(ws, cur, id_carga, logger)

            actualizar_carga(
                cur, id_carga, "Completado",
                cnt["leidas"], cnt["vacias"],
                cnt["secciones"], cnt["insertadas"]
            )
            conn.commit()

            total_filas_global  += cnt["leidas"]
            total_insert_global += cnt["insertadas"]
            alguna_ok = True

            logger.info(
                f"    ✓ Leídas:{cnt['leidas']} | Vacías:{cnt['vacias']} | "
                f"Secciones:{cnt['secciones']} | Encabezados:{cnt['encabezados']} | "
                f"Insertadas:{cnt['insertadas']} | Warnings:{cnt['warnings']}"
            )

        except Exception as e:
            conn.rollback()
            logger.error(f"    ERROR en hoja '{nombre_hoja}': {e}")
            try:
                actualizar_carga(cur, id_carga, "Error", 0, 0, 0, 0, str(e))
                conn.commit()
            except Exception:
                pass

    wb.close()

    estado_final = "Procesado" if alguna_ok else "Error"
    actualizar_archivo_log(
        cur, id_archivo, estado_final,
        total_filas_global, total_insert_global
    )
    conn.commit()
    cur.close()

    logger.info(
        f"  {'✓' if alguna_ok else '✗'} Estado: {estado_final} | "
        f"Total insertadas: {total_insert_global}"
    )
    return alguna_ok


# ─────────────────────────────────────────────────────────────────────────────
#  PUNTO DE ENTRADA  (RB-08)
# ─────────────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="ETL Landing — Fertilisa S.A. v2.0"
    )
    parser.add_argument("--input-dir", required=True,
                        help="Carpeta con los archivos .xlsx a procesar")
    parser.add_argument("--log-dir", default="logs",
                        help="Carpeta para archivos .log (default: ./logs)")
    parser.add_argument("--usuario", default=os.getenv("USER", "etl_proceso"),
                        help="Nombre del operario o proceso (se registra en BD)")
    args = parser.parse_args()

    logger = configurar_logging(args.log_dir)
    logger.info("=" * 60)
    logger.info("ETL LANDING — Fertilisa S.A.")
    logger.info(f"  Script version : {SCRIPT_VERSION}")
    logger.info(f"  Carpeta entrada: {args.input_dir}")
    logger.info(f"  Usuario        : {args.usuario}")
    logger.info("=" * 60)

    # Check 2: validar carpeta de entrada
    carpeta = Path(args.input_dir)
    if not carpeta.exists() or not carpeta.is_dir():
        logger.critical(f"La carpeta de entrada no existe: {args.input_dir}")
        sys.exit(1)

    archivos = sorted(carpeta.glob("*.xlsx"))
    if not archivos:
        logger.warning(f"No se encontraron archivos .xlsx en: {args.input_dir}")
        sys.exit(0)

    logger.info(f"Archivos encontrados: {len(archivos)}")
    for a in archivos:
        logger.info(f"  - {a.name}")

    # Check 3: conectar a BD (falla duro si no hay conexión)
    conn = conectar_db(logger)

    resultados = {"exitosos": 0, "duplicados": 0, "errores": 0}

    # RB-03: procesar todos los archivos; si uno falla, continuar con el siguiente
    for ruta_archivo in archivos:
        try:
            ok = procesar_archivo(ruta_archivo, conn, logger, args.usuario)
            if ok:
                resultados["exitosos"] += 1
            else:
                resultados["duplicados"] += 1
        except Exception as e:
            logger.error(f"Error inesperado procesando '{ruta_archivo.name}': {e}")
            try:
                conn.rollback()
            except Exception:
                pass
            resultados["errores"] += 1

    conn.close()

    logger.info("=" * 60)
    logger.info("RESUMEN")
    logger.info(f"  Exitosos   : {resultados['exitosos']}")
    logger.info(f"  Duplicados : {resultados['duplicados']}")
    logger.info(f"  Errores    : {resultados['errores']}")
    logger.info("=" * 60)

    sys.exit(0 if resultados["errores"] == 0 else 1)


if __name__ == "__main__":
    main()
