# consultora-pymes-core

Sistema RDBMS en SQL Server para la gestión operativa, financiera y de calidad de datos de PyMEs, modelado en Tercera Forma Normal (3FN), con un motor ETL de homologación y auditoría para la ingesta de datos desde planillas Excel.

> Este repositorio es la **versión corregida (v2)** del proyecto original. Ver [`CHANGELOG.md`](./CHANGELOG.md) para el detalle completo de qué se corrigió y por qué.

## Estructura del repositorio (Docs-as-Code)

```
dbml/   Modelado conceptual de datos (DBML), fuente de verdad del diseño relacional
sql/    Scripts DDL ejecutables y stored procedures (SQL Server)
docs/   Documentación técnica y manuales de operación por fase/módulo
```

## Módulos del sistema

1. **Terceros** (`tbl_terceros`): maestro unificado de clientes, proveedores y sponsors (patrón Business Partner).
2. **Productos y Servicios** (`tbl_productos_servicios`): catálogo unificado con extensiones ERP 1:1 y estructura de costos BOM/CBS.
3. **Contabilidad y Transacciones** (`cat_plan_cuentas`, `tbl_asientos_*`): partida doble con plan de cuentas estándar Chile.
4. **Transacciones Granulares** (`tbl_ordenes_compra`, `tbl_ventas_devengadas`, `tbl_movimientos_caja`): ciclo comercial y tesorería.
5. **Centros de Costo y Empleados**: dimensiones organizacionales (taxonomía APQC).
6. **Mapeo y Homologación** (`map_clientes`, `map_productos`): traducción de datos informales de Excel a IDs canónicos.
7. **Motor ETL (Fase 3)** (`tbl_staging_carga`, `tbl_log_errores_etl`, `sp_procesar_etl_fase3`): validación, auditoría y carga masiva al Core.

## Despliegue desde cero

Ejecutar en SQL Server Management Studio (SSMS), **en este orden exacto**:

```sql
-- 1. Terceros (prerrequisito de todo el modelo transaccional)
:r sql/crear_modulo_terceros.sql

-- 2. Contabilidad y plan de cuentas
:r sql/crear_modulo_contabilidad_transacciones.sql

-- 3. Productos, servicios y BOM/CBS
:r sql/crear_modulo_productos_servicios.sql

-- 4. Centros de costo y empleados
:r sql/crear_modulo_centros_costo_empleados.sql

-- 5. Transacciones granulares (compras, ventas, caja)
:r sql/crear_tablas_transaccionales_granular.sql

-- 6. Tablas de mapeo / homologación (Fase 2)
:r sql/crear_tablas_mapeo.sql

-- 7. Staging y auditoría de errores (Fase 3)
:r sql/crear_tabla_staging.sql
:r sql/crear_tabla_log_errores.sql

-- 8. Stored procedures
:r sql/sp_procesar_transaccion_externa.sql
:r sql/sp_procesar_etl_fase3.sql
```

Ver el detalle operativo completo en [`docs/manual_operacion_fase1.md`](./docs/manual_operacion_fase1.md) y [`docs/fase3_manual_operacion_fase3.md`](./docs/fase3_manual_operacion_fase3.md).

## Documentación

| Fase | Documento |
|---|---|
| Fase 1 (Core) | `docs/manual_operacion_fase1.md` |
| Fase 2 (Homologación) | `docs/manual_operacion_fase2.md` |
| Fase 3 (Motor ETL) | `docs/fase3_manual_operacion_fase3.md` |
| Módulos individuales | `docs/modulo_*.md` |
