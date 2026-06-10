# Sistema BI de Gestión de Inventarios - Fertilisa S.A.

## Curso: TI 6900 Inteligencia de Negocios | Proyecto Grupal 2 | I Semestre 2026

---

## Descripción del Problema

Fertilisa S.A. es una PYME panameña dedicada a la importación y distribución de insumos agrícolas especializados: fertilizantes granulares y solubles, líquidos, materiales para invernadero y productos biológicos. La empresa opera con un ERP transaccional (Sistema David) que registra existencias de inventario y realiza tomas físicas periódicas para contrastar el stock real contra el saldo del sistema.

El problema identificado es la ausencia de herramientas analíticas que permitan:

- Monitorear en tiempo real la exactitud del inventario (Inventory Record Accuracy - IRA).
- Identificar productos con riesgo de vencimiento próximo.
- Detectar automáticamente discrepancias entre el stock físico y el sistema ERP.
- Generar KPIs de gestión de inventario para la toma de decisiones gerenciales.

El análisis de la toma física reveló vulnerabilidades críticas: 12 SKUs con discrepancias en la categoría Granular-Solubles (diferencia neta de -708 unidades), 79 productos clasificados como críticos (37.44% del portafolio en semáforo rojo) y una alta concentración del inventario en pocas marcas proveedoras.

---

## Organización Analizada

**Fertilisa S.A.** - Panamá

La unidad analizada es el almacén / bodega central, responsable de la custodia, movimiento y control de inventario de todos los productos. El portafolio abarca tres líneas principales:

- Fertilizantes granulares y solubles (107 SKUs)
- Fertilizantes líquidos (76 SKUs)
- Material para invernaderos, sustrato y otros (28 SKUs)

---

## Integrantes del Equipo

| Nombre | Carné | Rol |
|---|---|---|
| Axel Brenes Mena | 2023236223 | Project Manager / ETL |
| Caleb Segura Rodríguez | 2024105617 | Scrum Master / Documentación |
| Marcell Lugo Brown | 2024083550 | Requerimientos / Modelo Dimensional |
| Olman Alberto Granados Quesada | 2024253509 | Arquitectura DWH / Base de Datos |
| Juan Diego Quirós Gómez | 2024165546 | Reglas ETL / Carga DWH |

**Profesor:** Michael Sánchez Soto

---

## Arquitectura de la Solución

La solución implementa una arquitectura BI completa con tres capas:

```
[Fuente Operacional]          [ETL]              [Data Warehouse]         [Visualización]
   Excel Resumen.xlsx   -->  EasyMorph   -->   PostgreSQL (fertiliza_dwh)  -->  Power BI
   (toma física)             (5 reglas)         (Star Schema)                   (5 dashboards)
```

### Modelo Dimensional (Star Schema)

El Data Warehouse en PostgreSQL implementa dos tablas de hechos y seis dimensiones:

**Tablas de Hechos:**
- `FACT_INVENTARIO` - Un registro por SKU por toma física.
- `FACT_DISCREPANCIA` - Un registro por SKU con diferencia entre físico y sistema.

**Dimensiones:**
- `DIM_TIEMPO` - Jerarquía temporal: Año > Trimestre > Mes > Semana > Día.
- `DIM_PRODUCTO` - Con soporte SCD Tipo 2 (historial de cambios en nombre, presentación y fecha de vencimiento).
- `DIM_CATEGORIA` - Dimensión conformada: Granular-Solubles, Líquidos, Invernaderos.
- `DIM_MARCA` - Dimensión conformada entre ambas tablas de hechos.
- `DIM_ESTADO_STOCK` - Disponible / Sin Stock / Pendiente / Bloqueado.
- `DIM_TIPO_DISCREPANCIA` - Clasifica el tipo y el impacto financiero de cada discrepancia.

### Proceso ETL (EasyMorph)

El flujo ETL consta de tres etapas con cinco transformaciones no triviales:

1. **Cleaning Stage** - Importación, conversión de tipos, eliminación de nulos y limpieza de apóstrofes en códigos de producto.
2. **Transforming Stage**
   - Transformación 1: Ramificación paralela desde `stg_inventario_raw` hacia múltiples flujos.
   - Transformación 2: Integración de tablas maestras (marca, unidad de medida, categoría).
   - Transformación 3: Separación de flujos de entradas y salidas hacia datasets temporales.
   - Transformación 4: Cruce de datos maestros con movimientos históricos.
   - Transformación 5: Derivación del semáforo de estancamiento y consolidación final.
3. **Load Stage** - Exportación al modelo dimensional en PostgreSQL.

### KPIs Implementados

| KPI | Fórmula | Meta |
|---|---|---|
| IRA (Inventory Record Accuracy) | (SKUs sin diferencia / Total SKUs) x 100 | > 95% |
| % Quiebre de stock | (SKUs con stock 0 / Total SKUs) x 100 | < 10% |
| Delta Unidades | Suma (Físico - Sistema) por categoría | = 0 |
| Riesgo de vencimiento | SKUs con fecha de vencimiento <= hoy + 365 días | 0 críticos |

---

## Herramientas Utilizadas

| Herramienta | Propósito |
|---|---|
| PostgreSQL | Base de datos del Data Warehouse |
| Python | Script inicial para landing|
| Azure | Almacenamiento en cloud de la base de datos|
| EasyMorph | Diseño y ejecución del proceso ETL |
| Power BI | Visualizaciones y dashboards analíticos |
| GitHub | Control de versiones y colaboración |
| WhatsApp / Zoom | Comunicación interna del equipo |

---

## Instrucciones de Ejecución

### Requisitos Previos

- PostgreSQL 14 o superior instalado y en ejecución.
- Python y sus librerias, para instalar correr pip install openpyxl psycopg2-binary python-dotenv
python etl_landing.py --input-dir ./archivos --log-dir ./logs --usuario juan
- EasyMorph (versión compatible con los archivos `.morph` del repositorio).
- Power BI Desktop para visualizar los archivos `.pbix`.
- Archivo fuente `Resumen.xlsx` con la toma física de inventario.

### Pasos

**1. Crear la base de datos y el esquema**

```sql
-- Ejecutar en PostgreSQL
CREATE DATABASE fertiliza_dwh;
\c fertiliza_dwh
```

Luego ejecutar los scripts en el siguiente orden:

```bash
psql -d fertiliza_dwh -f SQL/fertiliza_oltp.sql      -- Esquema operacional (landing)
psql -d fertiliza_dwh -f SQL/fertiliza_landing.sql   -- Tablas de staging
psql -d fertiliza_dwh -f SQL/fertiliza_dwh.sql       -- Modelo dimensional
```
**1.5 Ejecutar archivo Python**
   python etl_landing.py --input-dir ./archivos --log-dir ./logs --usuario juan
**2. Ejecutar el proceso ETL en EasyMorph**

Abrir EasyMorph y ejecutar los archivos en el siguiente orden desde `src/ETL/`:

```
1. Cleaning/cleaning_stg.morph
2. Transform/Transform1.morph
3. Transform/Transform2.morph
4. Transform/Transform4.morph
5. Transform/Transform5.morph
6. Transform/Transform6.morph
7. Dimensions-FactTable/Dimensiones y Fact.morph
```

Verificar que el archivo `Resumen.xlsx` esté en la ruta configurada dentro de cada archivo `.morph`.

**3. Validar la carga**

```sql
SELECT COUNT(*) FROM fertiliza_dwh.fact_inventario;
SELECT COUNT(*) FROM fertiliza_dwh.fact_discrepancia;
SELECT COUNT(*) FROM fertiliza_dwh.dim_producto;
```

**4. Abrir los dashboards en Power BI**

Abrir el archivo `Documentación/Dashboards Fertilisa.pbix` en Power BI Desktop y actualizar la conexión a la instancia local de PostgreSQL.

---

## Estructura del Repositorio

```
Proyecto2_bi/
│
├── Documentación/
│   ├── Dashboards Fertilisa.pbix          # Archivo Power BI con los 5 dashboards
│   ├── Presentación Talento humano para...# Presentación del proyecto
│   ├── Proyecto2 BI-3.pdf                 # Informe técnico final
│   ├── Requerimiento.md                   # Documento de requerimientos
│   └── reglas_consolidadas_fertilisa.md.pdf # Reglas de transformación ETL
│
└── src/
    └── ETL/
        │
        ├── Cleaning/
        │   └── cleaning_stg.morph         # Limpieza y preparación del staging
        │
        ├── Dimensions-FactTable/
        │   ├── Dimensiones y Fact.morph   # Carga final al modelo dimensional
        │   └── FactTemp.dset              # Dataset temporal de hechos
        │
        ├── Transform/
        │   ├── Transform1.morph           # Ramificación paralela desde staging
        │   ├── Transform2.morph           # Integración de tablas maestras
        │   ├── Transform4.morph           # Cruce de productos con movimientos
        │   ├── Transform5.morph           # Derivación del semáforo de estancamiento
        │   ├── Transform6.morph           # Consolidación final
        │   ├── TempEntradas.dset          # Dataset temporal de entradas
        │   ├── TempSalidas.dset           # Dataset temporal de salidas
        │   └── tempTransform.dset         # Dataset temporal intermedio
        │
        └── SQL/
            ├── fertiliza_dwh.sql          # DDL del modelo dimensional (DWH)
            ├── fertiliza_landing.sql      # DDL del esquema de staging
            └── fertiliza_oltp.sql         # DDL del esquema operacional
```

---

## Alcance y Limitaciones

**Dentro del alcance:**
- Diseño e implementación del modelo dimensional en PostgreSQL.
- Proceso ETL reproducible en EasyMorph con cinco reglas de transformación no triviales.
- Análisis de inventario físico versus sistema ERP.
- Cinco dashboards analíticos en Power BI.

**Fuera del alcance:**
- Integración en tiempo real con el ERP Sistema David (se realizó de forma manual mediante importación de archivo).
- Módulo de compras o ventas.
- Análisis de tendencias históricas (la fuente es una única toma física estática).

---

## Criterios de Éxito

- IRA calculado y trazable por categoría de producto.
- Discrepancias clasificadas por tipo e impacto financiero.
- Los seis KPIs responden las preguntas de negocio definidas.
- El proceso ETL es reproducible ante cada nueva toma física.
