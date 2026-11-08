# Módulo: Productos, Servicios y Composición de Costos (BOM / CBS)

## Objetivo
Estandarizar el catálogo de ítems de la consultora y sus clientes PyME, permitiendo gestionar tanto bienes tangibles (con control de inventario y logística) como servicios intangibles (con asignación de perfiles profesionales y costos de horas hombre).

## Arquitectura y Patrones de Diseño
1. **Cabecera Unificada (`tbl_productos_servicios`)**: Contiene los atributos comunes de cualquier producto o servicio (SKU, nombre, tipo, categoría, unidad de medida y precio base).
2. **Patrón de Extensión ERP (Tablas 1:1)**:
   - `tbl_item_extension_producto`: Atributos logísticos y de inventario (stock mínimo, peso, dimensiones).
   - `tbl_item_extension_servicio`: Atributos operativos (modalidad de entrega, SLA, soporte).
3. **Estructura BOM / CBS (Bill of Materials / Cost Breakdown Structure)**:
   - `tbl_item_composicion_hh`: Define las horas requeridas por perfil profesional (`cat_perfiles_hh`) para ejecutar un servicio.
   - `tbl_item_composicion_insumos`: Define los insumos o materiales necesarios (`cat_insumos_recursos`).

## Vista Financiera de Costeo (`vw_productos_servicios_costeo`)
Permite calcular en tiempo real el costo total base y el margen de contribución de cada producto o servicio a partir de sus componentes atómicos.