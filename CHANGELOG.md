# Changelog

## v2 — Auditoría y corrección integral (Nov 2026)

Corrección derivada de una auditoría arquitectónica completa del repositorio original (`consultora-pymes-core`), cubriendo DBML, SQL y documentación.

### Críticos

1. **FKs faltantes de `id_tercero`.** `tbl_transacciones_cabecera`, `tbl_ordenes_compra`, `tbl_ventas_devengadas` y `tbl_movimientos_caja` declaraban `id_tercero` solo en comentario, sin `CONSTRAINT FOREIGN KEY` real ni en SQL ni en DBML. Se agregaron las 4 FKs hacia `tbl_terceros`.
2. **Orden de despliegue incompleto.** El manual de Fase 1 nunca incluía `crear_modulo_terceros.sql`, por lo que siguiendo el manual al pie de la letra `tbl_terceros` jamás se creaba. Se corrigió el orden y se agregó como paso obligatorio inicial.
3. **`map_productos` nunca se creaba.** Estaba documentada, modelada en DBML y referenciada en `sp_procesar_transaccion_externa.sql`, pero no existía ningún `CREATE TABLE map_productos`. Se agregó en `sql/crear_tablas_mapeo.sql`, con `UNIQUE` y FK hacia `tbl_productos_servicios` (y se agregó la FK que también faltaba en `map_clientes`).
4. **`sp_procesar_venta_externa` no insertaba nada en el Core.** El `INSERT` hacia `tbl_ventas_devengadas`/`tbl_ventas_detalle` estaba comentado como "ejemplo conceptual". Se implementó el insert real, con cálculo de neto/IVA/total según `aplica_iva` del ítem homologado.
5. **El motor ETL (`sp_procesar_etl_fase3`) solo auditaba, nunca cargaba al Core**, y validaba apenas 2 de las ~10 reglas que la propia especificación (`docs/fase3_motor_etl.md`) exigía (faltaban: formato de fecha, homologación de producto, reglas de `Movimientos_Caja`, distinción entre las 3 pestañas). Se reescribió completo: valida por archivo/pestaña, cubre todas las reglas documentadas, y carga las filas válidas al Core dentro de una transacción atómica.
6. **`tbl_staging_carga` no podía representar las 3 pestañas del Excel.** Tenía un esquema genérico (cliente/producto/cantidad/monto) sin campos para `estado_venta`/`estado_oc`, `tipo_flujo`, `cuenta_bancaria` ni `glosa`, y columnas tipadas (`DATE`, `DECIMAL`) que rechazaban silenciosamente cualquier fila mal formateada antes de poder auditarla. Se rediseñó con columnas `VARCHAR` crudas para las 3 pestañas, más `nombre_archivo` y `pestana_origen` para aislar cada corrida de carga.

### Medios

7. **Fan-out (producto cartesiano) en `vw_productos_servicios_costeo`.** El doble `LEFT JOIN` (horas-hombre × insumos) inflaba los costos cuando un ítem tenía líneas en ambas composiciones. Se corrigió agregando cada costo en una CTE independiente antes de unir 1:1 por ítem.

### Menores

8. Typo en DBML: `cat_insumos_recursos.id_insumos` → `id_insumo`.
9. Desalineación de nombres: DBML usaba `id_cc_padre`, el SQL real usa `id_centro_padre`. Se alineó el DBML.
10. `docs/fase3_manual_operacion_fase3.md` estaba incompleto (cortaba a mitad del Paso 1). Se completó con los 6 pasos operativos y la tabla de códigos de error.
11. Se actualizaron `docs/fase3_especificacion_staging.md`, `docs/fase3_especificacion_etl.md` y `docs/fase3_motor_etl.md` para reflejar fielmente el diseño v2.

### Sin cambios (evaluado y considerado correcto)

- Modelo relacional de Fase 1 (Terceros, Productos/Servicios, Contabilidad): 3FN correctamente aplicada, patrón Business Partner, patrón de extensión ERP 1:1, partida doble y plan de cuentas chileno. No se encontraron deficiencias que justificaran cambios estructurales.
- Estrategia de llaves primarias manuales (no `IDENTITY`) en las tablas transaccionales: se mantuvo sin cambios para no alterar los scripts de demostración existentes; el motor ETL calcula el siguiente ID de forma segura (`MAX() + ROW_NUMBER()`) dentro de la misma transacción.
