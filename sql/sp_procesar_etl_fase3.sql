-- ====================================================================
-- Proyecto: Sistema RDBMS para PyMEs (Fase 3)
-- Objeto: Stored Procedure de Validación, Auditoría y Carga Masiva ETL
-- ====================================================================
-- PRERREQUISITOS: Ejecutar previamente, en este orden:
--   1) sql/crear_modulo_terceros.sql
--   2) sql/crear_modulo_productos_servicios.sql
--   3) sql/crear_modulo_contabilidad_transacciones.sql
--   4) sql/crear_tablas_transaccionales_granular.sql
--   5) sql/crear_tablas_mapeo.sql
--   6) sql/crear_tabla_staging.sql
--   7) sql/crear_tabla_log_errores.sql
--
-- CAMBIOS RESPECTO A LA VERSIÓN ANTERIOR (v1 -> v2):
--   1. Las validaciones quedan acotadas a @nombre_archivo (y opcionalmente
--      @pestana_origen); v1 validaba la totalidad de tbl_staging_carga en
--      cada corrida, re-auditando filas de cargas anteriores.
--   2. Se agregan las validaciones de formato de fecha y de homologación
--      de producto/insumo que exige docs/fase3_motor_etl.md y que v1 no
--      implementaba.
--   3. Se agrega la validación propia de Movimientos_Caja (cuenta
--      bancaria existente en cat_plan_cuentas y tipo_flujo en dominio).
--   4. Se agrega el paso que v1 no tenía: la carga real de las filas que
--      superan todas las validaciones hacia las tablas del Core
--      (tbl_ventas_devengadas/detalle, tbl_ordenes_compra/detalle,
--      tbl_movimientos_caja), dentro de una transacción atómica.
-- ====================================================================

USE consultora_pymes_core;
GO

IF OBJECT_ID('dbo.sp_procesar_etl_fase3', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_procesar_etl_fase3;
GO

CREATE PROCEDURE dbo.sp_procesar_etl_fase3
    @nombre_archivo VARCHAR(150),
    @pestana_origen VARCHAR(50) = NULL   -- NULL = procesar las 3 pestañas presentes para este archivo
AS
BEGIN
    SET NOCOUNT ON;

    PRINT '------------------------------------------------';
    PRINT 'Iniciando validación ETL para el archivo: ' + @nombre_archivo;
    PRINT '------------------------------------------------';

    BEGIN TRY

        ------------------------------------------------------------------
        -- 0. Reiniciar el estado de esta corrida (solo para este archivo)
        ------------------------------------------------------------------
        DELETE FROM dbo.tbl_log_errores_etl
        WHERE nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR pestana_origen = @pestana_origen);

        UPDATE dbo.tbl_staging_carga
        SET estado_carga = 'PENDIENTE', fecha_proceso = NULL
        WHERE nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR pestana_origen = @pestana_origen)
          AND estado_carga <> 'CARGADO';

        ------------------------------------------------------------------
        -- 1. VALIDACIONES COMUNES A Ventas_Devengadas Y Compras_y_Gastos
        ------------------------------------------------------------------

        -- 1.1 Formato de fecha inválido (se exige AAAA-MM-DD estricto)
        INSERT INTO dbo.tbl_log_errores_etl (nombre_archivo, pestana_origen, numero_fila, tipo_error, detalle_mensaje)
        SELECT nombre_archivo, pestana_origen, numero_fila, 'FORMATO_FECHA_INVALIDO',
               'El valor de fecha [' + ISNULL(fecha_raw, 'VACIO') + '] no cumple el formato AAAA-MM-DD.'
        FROM dbo.tbl_staging_carga
        WHERE nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR pestana_origen = @pestana_origen)
          AND estado_carga = 'PENDIENTE'
          AND (fecha_raw IS NULL
               OR fecha_raw NOT LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
               OR TRY_CONVERT(DATE, fecha_raw, 23) IS NULL);

        -- 1.2 Cliente / Proveedor no homologado (map_clientes homologa cualquier
        --     tercero -- cliente o proveedor -- hacia tbl_terceros)
        INSERT INTO dbo.tbl_log_errores_etl (nombre_archivo, pestana_origen, numero_fila, tipo_error, detalle_mensaje)
        SELECT t.nombre_archivo, t.pestana_origen, t.numero_fila, 'CLIENTE_NO_HOMOLOGADO',
               'El tercero informal [' + ISNULL(t.tercero_informal_raw, 'VACIO') + '] no se encuentra homologado en map_clientes.'
        FROM dbo.tbl_staging_carga t
        LEFT JOIN dbo.map_clientes c ON t.tercero_informal_raw = c.nombre_informal_excel
        WHERE t.nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR t.pestana_origen = @pestana_origen)
          AND t.estado_carga = 'PENDIENTE'
          AND t.pestana_origen IN ('Ventas_Devengadas', 'Compras_y_Gastos')
          AND c.id_map_cliente IS NULL;

        -- 1.3 Ítem / Insumo no homologado
        INSERT INTO dbo.tbl_log_errores_etl (nombre_archivo, pestana_origen, numero_fila, tipo_error, detalle_mensaje)
        SELECT t.nombre_archivo, t.pestana_origen, t.numero_fila, 'ITEM_NO_HOMOLOGADO',
               'La descripción de ítem [' + ISNULL(t.item_informal_raw, 'VACIO') + '] no se encuentra homologada en map_productos.'
        FROM dbo.tbl_staging_carga t
        LEFT JOIN dbo.map_productos p ON t.item_informal_raw = p.descripcion_libre_excel
        WHERE t.nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR t.pestana_origen = @pestana_origen)
          AND t.estado_carga = 'PENDIENTE'
          AND t.pestana_origen IN ('Ventas_Devengadas', 'Compras_y_Gastos')
          AND p.id_map_producto IS NULL;

        -- 1.4 Cantidad inválida (debe ser numérica y > 0)
        INSERT INTO dbo.tbl_log_errores_etl (nombre_archivo, pestana_origen, numero_fila, tipo_error, detalle_mensaje)
        SELECT nombre_archivo, pestana_origen, numero_fila, 'CANTIDAD_INVALIDA',
               'La cantidad [' + ISNULL(cantidad_raw, 'VACIO') + '] no es numérica o no es mayor a cero.'
        FROM dbo.tbl_staging_carga
        WHERE nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR pestana_origen = @pestana_origen)
          AND estado_carga = 'PENDIENTE'
          AND pestana_origen IN ('Ventas_Devengadas', 'Compras_y_Gastos')
          AND (TRY_CAST(cantidad_raw AS DECIMAL(18,4)) IS NULL OR TRY_CAST(cantidad_raw AS DECIMAL(18,4)) <= 0);

        -- 1.5 Precio unitario inválido (debe ser numérico y >= 0)
        INSERT INTO dbo.tbl_log_errores_etl (nombre_archivo, pestana_origen, numero_fila, tipo_error, detalle_mensaje)
        SELECT nombre_archivo, pestana_origen, numero_fila, 'PRECIO_INVALIDO',
               'El precio unitario [' + ISNULL(precio_unitario_raw, 'VACIO') + '] no es numérico o es negativo.'
        FROM dbo.tbl_staging_carga
        WHERE nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR pestana_origen = @pestana_origen)
          AND estado_carga = 'PENDIENTE'
          AND pestana_origen IN ('Ventas_Devengadas', 'Compras_y_Gastos')
          AND (TRY_CAST(precio_unitario_raw AS DECIMAL(18,2)) IS NULL OR TRY_CAST(precio_unitario_raw AS DECIMAL(18,2)) < 0);

        -- 1.6 Folio vacío
        INSERT INTO dbo.tbl_log_errores_etl (nombre_archivo, pestana_origen, numero_fila, tipo_error, detalle_mensaje)
        SELECT nombre_archivo, pestana_origen, numero_fila, 'FOLIO_VACIO',
               'El folio del documento no fue informado.'
        FROM dbo.tbl_staging_carga
        WHERE nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR pestana_origen = @pestana_origen)
          AND estado_carga = 'PENDIENTE'
          AND pestana_origen IN ('Ventas_Devengadas', 'Compras_y_Gastos')
          AND (folio_documento_raw IS NULL OR LTRIM(RTRIM(folio_documento_raw)) = '');

        -- 1.7 Estado de documento fuera de dominio
        INSERT INTO dbo.tbl_log_errores_etl (nombre_archivo, pestana_origen, numero_fila, tipo_error, detalle_mensaje)
        SELECT nombre_archivo, pestana_origen, numero_fila, 'ESTADO_INVALIDO',
               'El estado [' + ISNULL(estado_documento_raw, 'VACIO') + '] no es válido para la pestaña ' + pestana_origen + '.'
        FROM dbo.tbl_staging_carga
        WHERE nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR pestana_origen = @pestana_origen)
          AND estado_carga = 'PENDIENTE'
          AND (
                (pestana_origen = 'Ventas_Devengadas' AND estado_documento_raw NOT IN ('DEVENGADO','FACTURADO','PAGADO','ANULADO'))
             OR (pestana_origen = 'Compras_y_Gastos'  AND estado_documento_raw NOT IN ('BORRADOR','APROBADA','RECIBIDA','ANULADA'))
              );

        ------------------------------------------------------------------
        -- 2. VALIDACIONES PROPIAS DE Movimientos_Caja
        ------------------------------------------------------------------

        -- 2.1 Cuenta bancaria no existe en el plan de cuentas
        INSERT INTO dbo.tbl_log_errores_etl (nombre_archivo, pestana_origen, numero_fila, tipo_error, detalle_mensaje)
        SELECT t.nombre_archivo, t.pestana_origen, t.numero_fila, 'CUENTA_BANCARIA_NO_EXISTE',
               'El código de cuenta [' + ISNULL(t.cuenta_bancaria_raw, 'VACIO') + '] no existe en cat_plan_cuentas.'
        FROM dbo.tbl_staging_carga t
        LEFT JOIN dbo.cat_plan_cuentas cp ON t.cuenta_bancaria_raw = cp.codigo_cuenta
        WHERE t.nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR t.pestana_origen = @pestana_origen)
          AND t.estado_carga = 'PENDIENTE'
          AND t.pestana_origen = 'Movimientos_Caja'
          AND cp.id_cuenta IS NULL;

        -- 2.2 Tipo de flujo fuera de dominio
        INSERT INTO dbo.tbl_log_errores_etl (nombre_archivo, pestana_origen, numero_fila, tipo_error, detalle_mensaje)
        SELECT nombre_archivo, pestana_origen, numero_fila, 'TIPO_FLUJO_INVALIDO',
               'El tipo de flujo [' + ISNULL(tipo_flujo_raw, 'VACIO') + '] no es válido.'
        FROM dbo.tbl_staging_carga
        WHERE nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR pestana_origen = @pestana_origen)
          AND estado_carga = 'PENDIENTE'
          AND pestana_origen = 'Movimientos_Caja'
          AND (tipo_flujo_raw IS NULL OR tipo_flujo_raw NOT IN ('INGRESO','EGRESO','TRASPASO_HASTA','TRASPASO_DESDE'));

        -- 2.3 Monto absoluto inválido (numérico y > 0)
        INSERT INTO dbo.tbl_log_errores_etl (nombre_archivo, pestana_origen, numero_fila, tipo_error, detalle_mensaje)
        SELECT nombre_archivo, pestana_origen, numero_fila, 'MONTO_INVALIDO',
               'El monto absoluto [' + ISNULL(monto_absoluto_raw, 'VACIO') + '] no es numérico o no es mayor a cero.'
        FROM dbo.tbl_staging_carga
        WHERE nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR pestana_origen = @pestana_origen)
          AND estado_carga = 'PENDIENTE'
          AND pestana_origen = 'Movimientos_Caja'
          AND (TRY_CAST(monto_absoluto_raw AS DECIMAL(18,2)) IS NULL OR TRY_CAST(monto_absoluto_raw AS DECIMAL(18,2)) <= 0);

        -- 2.4 Glosa obligatoria vacía
        INSERT INTO dbo.tbl_log_errores_etl (nombre_archivo, pestana_origen, numero_fila, tipo_error, detalle_mensaje)
        SELECT nombre_archivo, pestana_origen, numero_fila, 'GLOSA_VACIA',
               'La glosa del movimiento de caja no fue informada.'
        FROM dbo.tbl_staging_carga
        WHERE nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR pestana_origen = @pestana_origen)
          AND estado_carga = 'PENDIENTE'
          AND pestana_origen = 'Movimientos_Caja'
          AND (glosa IS NULL OR LTRIM(RTRIM(glosa)) = '');

        ------------------------------------------------------------------
        -- 3. MARCAR COMO RECHAZADAS LAS FILAS CON AL MENOS UN ERROR
        ------------------------------------------------------------------
        UPDATE t
        SET t.estado_carga = 'RECHAZADO', t.fecha_proceso = GETDATE()
        FROM dbo.tbl_staging_carga t
        WHERE t.nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR t.pestana_origen = @pestana_origen)
          AND t.estado_carga = 'PENDIENTE'
          AND EXISTS (
                SELECT 1 FROM dbo.tbl_log_errores_etl e
                WHERE e.nombre_archivo = t.nombre_archivo
                  AND e.pestana_origen = t.pestana_origen
                  AND e.numero_fila = t.numero_fila
              );

        ------------------------------------------------------------------
        -- 4. CARGA ATÓMICA AL CORE DE LAS FILAS QUE SIGUEN "PENDIENTE"
        --    (superaron todas las validaciones anteriores)
        ------------------------------------------------------------------
        BEGIN TRANSACTION;

            -- Resolución de homologaciones e IDs de negocio en una tabla temporal
            SELECT
                t.id_staging, t.pestana_origen, t.folio_documento_raw,
                mc.id_tercero_oficial, mp.id_item_oficial,
                TRY_CONVERT(DATE, t.fecha_raw, 23)                AS fecha_doc,
                TRY_CAST(t.cantidad_raw AS DECIMAL(18,4))         AS cantidad,
                TRY_CAST(t.precio_unitario_raw AS DECIMAL(18,2))  AS precio_unitario,
                CAST(t.cantidad_raw AS DECIMAL(18,4)) * CAST(t.precio_unitario_raw AS DECIMAL(18,2)) AS subtotal_neto,
                p.aplica_iva,
                t.estado_documento_raw
            INTO #resuelto_comercial
            FROM dbo.tbl_staging_carga t
            LEFT JOIN dbo.map_clientes mc ON t.tercero_informal_raw = mc.nombre_informal_excel
            LEFT JOIN dbo.map_productos mp ON t.item_informal_raw = mp.descripcion_libre_excel
            LEFT JOIN dbo.tbl_productos_servicios p ON mp.id_item_oficial = p.id_item
            WHERE t.nombre_archivo = @nombre_archivo
              AND (@pestana_origen IS NULL OR t.pestana_origen = @pestana_origen)
              AND t.estado_carga = 'PENDIENTE'
              AND t.pestana_origen IN ('Ventas_Devengadas', 'Compras_y_Gastos');

            ---------------------------------------------------
            -- 4.1 VENTAS_DEVENGADAS: cabecera (por folio) + detalle
            ---------------------------------------------------
            INSERT INTO dbo.tbl_ventas_devengadas
                (id_venta_devengada, folio_factura, id_tercero, fecha_emision, monto_neto, monto_iva, monto_total, estado_venta)
            SELECT
                (SELECT ISNULL(MAX(id_venta_devengada), 0) FROM dbo.tbl_ventas_devengadas)
                    + ROW_NUMBER() OVER (ORDER BY r.folio_documento_raw),
                r.folio_documento_raw,
                MIN(r.id_tercero_oficial),
                MIN(r.fecha_doc),
                SUM(r.subtotal_neto),
                SUM(CASE WHEN r.aplica_iva = 1 THEN r.subtotal_neto * 0.19 ELSE 0 END),
                SUM(r.subtotal_neto) + SUM(CASE WHEN r.aplica_iva = 1 THEN r.subtotal_neto * 0.19 ELSE 0 END),
                MIN(r.estado_documento_raw)
            FROM #resuelto_comercial r
            WHERE r.pestana_origen = 'Ventas_Devengadas'
              AND NOT EXISTS (SELECT 1 FROM dbo.tbl_ventas_devengadas v WHERE v.folio_factura = r.folio_documento_raw)
            GROUP BY r.folio_documento_raw;

            INSERT INTO dbo.tbl_ventas_detalle
                (id_venta_detalle, id_venta_devengada, id_item, cantidad, precio_unitario, subtotal_neto)
            SELECT
                (SELECT ISNULL(MAX(id_venta_detalle), 0) FROM dbo.tbl_ventas_detalle)
                    + ROW_NUMBER() OVER (ORDER BY r.id_staging),
                v.id_venta_devengada,
                r.id_item_oficial,
                r.cantidad,
                r.precio_unitario,
                r.subtotal_neto
            FROM #resuelto_comercial r
            INNER JOIN dbo.tbl_ventas_devengadas v ON v.folio_factura = r.folio_documento_raw
            WHERE r.pestana_origen = 'Ventas_Devengadas';

            ---------------------------------------------------
            -- 4.2 COMPRAS_Y_GASTOS: cabecera (por folio) + detalle
            ---------------------------------------------------
            INSERT INTO dbo.tbl_ordenes_compra
                (id_orden_compra, folio_oc, id_tercero, fecha_emision, monto_neto, monto_iva, monto_total, estado_oc)
            SELECT
                (SELECT ISNULL(MAX(id_orden_compra), 0) FROM dbo.tbl_ordenes_compra)
                    + ROW_NUMBER() OVER (ORDER BY r.folio_documento_raw),
                r.folio_documento_raw,
                MIN(r.id_tercero_oficial),
                MIN(r.fecha_doc),
                SUM(r.subtotal_neto),
                SUM(CASE WHEN r.aplica_iva = 1 THEN r.subtotal_neto * 0.19 ELSE 0 END),
                SUM(r.subtotal_neto) + SUM(CASE WHEN r.aplica_iva = 1 THEN r.subtotal_neto * 0.19 ELSE 0 END),
                MIN(r.estado_documento_raw)
            FROM #resuelto_comercial r
            WHERE r.pestana_origen = 'Compras_y_Gastos'
              AND NOT EXISTS (SELECT 1 FROM dbo.tbl_ordenes_compra o WHERE o.folio_oc = r.folio_documento_raw)
            GROUP BY r.folio_documento_raw;

            INSERT INTO dbo.tbl_compras_detalle
                (id_compra_detalle, id_orden_compra, id_item, cantidad, precio_unitario, subtotal_neto)
            SELECT
                (SELECT ISNULL(MAX(id_compra_detalle), 0) FROM dbo.tbl_compras_detalle)
                    + ROW_NUMBER() OVER (ORDER BY r.id_staging),
                o.id_orden_compra,
                r.id_item_oficial,
                r.cantidad,
                r.precio_unitario,
                r.subtotal_neto
            FROM #resuelto_comercial r
            INNER JOIN dbo.tbl_ordenes_compra o ON o.folio_oc = r.folio_documento_raw
            WHERE r.pestana_origen = 'Compras_y_Gastos';

            DROP TABLE #resuelto_comercial;

            ---------------------------------------------------
            -- 4.3 MOVIMIENTOS_CAJA: inserción directa (sin cabecera)
            ---------------------------------------------------
            INSERT INTO dbo.tbl_movimientos_caja
                (id_movimiento, fecha_movimiento, id_cuenta_bancaria, tipo_flujo, monto_absoluto, glosa_movimiento, id_tercero)
            SELECT
                (SELECT ISNULL(MAX(id_movimiento), 0) FROM dbo.tbl_movimientos_caja)
                    + ROW_NUMBER() OVER (ORDER BY t.id_staging),
                TRY_CONVERT(DATE, t.fecha_raw, 23),
                cp.id_cuenta,
                t.tipo_flujo_raw,
                TRY_CAST(t.monto_absoluto_raw AS DECIMAL(18,2)),
                t.glosa,
                mc.id_tercero_oficial
            FROM dbo.tbl_staging_carga t
            INNER JOIN dbo.cat_plan_cuentas cp ON t.cuenta_bancaria_raw = cp.codigo_cuenta
            LEFT JOIN dbo.map_clientes mc ON t.tercero_informal_raw = mc.nombre_informal_excel
            WHERE t.nombre_archivo = @nombre_archivo
              AND (@pestana_origen IS NULL OR t.pestana_origen = @pestana_origen)
              AND t.estado_carga = 'PENDIENTE'
              AND t.pestana_origen = 'Movimientos_Caja';

            ---------------------------------------------------
            -- 4.4 Marcar como CARGADAS todas las filas que acaban de integrarse
            ---------------------------------------------------
            UPDATE dbo.tbl_staging_carga
            SET estado_carga = 'CARGADO', fecha_proceso = GETDATE()
            WHERE nombre_archivo = @nombre_archivo
              AND (@pestana_origen IS NULL OR pestana_origen = @pestana_origen)
              AND estado_carga = 'PENDIENTE';

        COMMIT TRANSACTION;

        PRINT 'Proceso de validación, auditoría y carga al Core completado con éxito.';

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR('Error en sp_procesar_etl_fase3: %s', 16, 1, @ErrorMessage);
    END CATCH
END;
GO
