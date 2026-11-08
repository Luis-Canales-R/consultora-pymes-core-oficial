USE consultora_pymes_core;
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ======================================================================
-- STORED PROCEDURE: sp_procesar_venta_externa
-- PROPÓSITO: Recibe datos de la plantilla de Excel (fila a fila, uso
--            interactivo / puntual), homologa nombres informales mediante
--            las tablas de mapeo de Fase 2 y realiza el insert seguro en
--            el Core RDBMS transaccional (cabecera + detalle de venta).
--
-- NOTA: Para cargas masivas por lote use dbo.sp_procesar_etl_fase3, que
--       trabaja sobre dbo.tbl_staging_carga y audita cada fila en
--       dbo.tbl_log_errores_etl. Este procedimiento es para procesar
--       o corregir una venta puntual sin pasar por staging.
-- ======================================================================
CREATE OR ALTER PROCEDURE sp_procesar_venta_externa
    @folio_factura VARCHAR(50),
    @fecha_emision DATE,
    @nombre_informal_cliente VARCHAR(150),
    @descripcion_libre_item VARCHAR(150),
    @cantidad DECIMAL(18,4),
    @precio_unitario DECIMAL(18,2),
    @estado_venta VARCHAR(30)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @id_tercero_oficial INT;
    DECLARE @id_item_oficial INT;
    DECLARE @aplica_iva BIT;
    DECLARE @id_venta_devengada INT;
    DECLARE @subtotal_neto DECIMAL(18,2);
    DECLARE @monto_iva DECIMAL(18,2);
    DECLARE @monto_total DECIMAL(18,2);

    BEGIN TRY
        -- 1. Validación y Homologación de Cliente
        SELECT @id_tercero_oficial = id_tercero_oficial
        FROM map_clientes
        WHERE nombre_informal_excel = @nombre_informal_cliente;

        IF @id_tercero_oficial IS NULL
        BEGIN
            RAISERROR('El cliente informal "%s" no se encuentra homologado en map_clientes.', 16, 1, @nombre_informal_cliente);
            RETURN;
        END

        -- 2. Validación y Homologación de Producto / Servicio
        SELECT @id_item_oficial = p.id_item, @aplica_iva = p.aplica_iva
        FROM map_productos mp
        INNER JOIN tbl_productos_servicios p ON mp.id_item_oficial = p.id_item
        WHERE mp.descripcion_libre_excel = @descripcion_libre_item;

        IF @id_item_oficial IS NULL
        BEGIN
            RAISERROR('La descripción de ítem "%s" no se encuentra homologada en map_productos.', 16, 1, @descripcion_libre_item);
            RETURN;
        END

        -- 3. Validaciones de negocio básicas
        IF @cantidad IS NULL OR @cantidad <= 0
        BEGIN
            RAISERROR('La cantidad debe ser numérica y mayor a cero.', 16, 1);
            RETURN;
        END

        IF @precio_unitario IS NULL OR @precio_unitario < 0
        BEGIN
            RAISERROR('El precio unitario debe ser numérico y no puede ser negativo.', 16, 1);
            RETURN;
        END

        -- 4. Cálculo de montos (neto / IVA / total) según el ítem homologado
        SET @subtotal_neto = @cantidad * @precio_unitario;
        SET @monto_iva = CASE WHEN @aplica_iva = 1 THEN ROUND(@subtotal_neto * 0.19, 2) ELSE 0 END;
        SET @monto_total = @subtotal_neto + @monto_iva;

        -- 5. Inserción Transaccional Segura hacia el Core
        BEGIN TRANSACTION;

            IF EXISTS (SELECT 1 FROM tbl_ventas_devengadas WHERE folio_factura = @folio_factura)
            BEGIN
                RAISERROR('El folio "%s" ya existe en tbl_ventas_devengadas. Use un folio único por documento.', 16, 1, @folio_factura);
                ROLLBACK TRANSACTION;
                RETURN;
            END

            SELECT @id_venta_devengada = ISNULL(MAX(id_venta_devengada), 0) + 1 FROM tbl_ventas_devengadas;

            INSERT INTO tbl_ventas_devengadas
                (id_venta_devengada, folio_factura, id_tercero, fecha_emision, monto_neto, monto_iva, monto_total, estado_venta)
            VALUES
                (@id_venta_devengada, @folio_factura, @id_tercero_oficial, @fecha_emision, @subtotal_neto, @monto_iva, @monto_total, @estado_venta);

            INSERT INTO tbl_ventas_detalle
                (id_venta_detalle, id_venta_devengada, id_item, cantidad, precio_unitario, subtotal_neto)
            VALUES
                ((SELECT ISNULL(MAX(id_venta_detalle), 0) + 1 FROM tbl_ventas_detalle),
                 @id_venta_devengada, @id_item_oficial, @cantidad, @precio_unitario, @subtotal_neto);

        COMMIT TRANSACTION;
        PRINT 'Transacción procesada e integrada al Core exitosamente. id_venta_devengada = ' + CAST(@id_venta_devengada AS VARCHAR(20));

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR(@ErrorMessage, 16, 1);
    END CATCH
END;
GO
