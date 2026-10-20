-- =====================================================================
-- 05_marts.sql — Tablas MART: KPIs ya calculados para los tableros
-- =====================================================================
-- Criterio de la materia: los KPIs se calculan en SQL y se MATERIALIZAN
-- en tablas; el tablero solo las lee y las muestra (sin sumar, promediar
-- ni dividir).
--
-- Un promedio calculado no se puede re-agregar: el ticket de "2025" no
-- sale de promediar los tickets de cada mes. Por eso cada mart trae una
-- fila por CADA combinación de filtros que ofrece el tablero:
--   period    'Todo', '2024', '2025' o un mes ('2024-01' … '2025-09')
--   channel   'Todos', 'ONLINE', 'OFFLINE'
--   province  'Todas', 'Buenos Aires', 'Córdoba', 'Santa Fe', 'Mendoza'
-- Las filas 'Todos' / 'Todas' las genera GROUPING SETS (vía CUBE): es el
-- total sobre esa dimensión, calculado en SQL, no una suma del tablero.
--
-- "Sin IVA" = total_amount - tax_amount (se descuenta el impuesto y se
-- mantiene el envío, que es ingreso de la empresa).
-- =====================================================================


-- ---------------------------------------------------------------------
-- Base: cada pedido repetido en sus tres períodos (total, año y mes)
-- ---------------------------------------------------------------------
-- Así un solo GROUP BY calcula los tres niveles con la misma lógica.

CREATE TEMP VIEW order_periods AS
WITH base AS (
    SELECT f.*, d.year, d.year_month, c.code AS channel, p.name AS province
    FROM fact_sales_order AS f
    JOIN dim_date     AS d ON d.date_key     = f.order_date_key
    JOIN dim_channel  AS c ON c.channel_key  = f.channel_key
    JOIN dim_province AS p ON p.province_key = f.province_key
)
SELECT 'total' AS period_type, 'Todo'                    AS period, * FROM base
UNION ALL
SELECT 'year',                 CAST(year AS VARCHAR),               * FROM base
UNION ALL
SELECT 'month',                year_month,                          * FROM base;


-- ---------------------------------------------------------------------
-- mart_sales_kpi — un período x canal x provincia (con totales)
-- ---------------------------------------------------------------------
-- Responde las 3 preguntas: cuánto vendimos (con y sin IVA), cuántos
-- pedidos cuentan como venta y el ticket promedio por canal.

CREATE TABLE mart_sales_kpi AS
SELECT
    period_type,
    period,
    COALESCE(channel,  'Todos')                                       AS channel,
    COALESCE(province, 'Todas')                                       AS province,
    COUNT(*)                                                          AS orders_total,       -- todos los pedidos
    SUM(sale_count)                                                   AS sale_orders,        -- pedidos que son venta
    COUNT(*) - SUM(sale_count)                                        AS non_sale_orders,    -- pedidos que no son venta
    ROUND(SUM(sale_count) * 1.0 / COUNT(*), 4)                        AS sale_order_share,   -- 0 a 1
    SUM(sales_amount)                                                 AS sales_amount,       -- con IVA y envío
    SUM(sales_net_amount)                                             AS sales_net_amount,   -- sin IVA
    SUM(tax_amount)   FILTER (WHERE is_sale)                          AS sales_tax_amount,   -- IVA de las ventas
    SUM(shipping_fee) FILTER (WHERE is_sale)                          AS sales_shipping_amount,
    SUM(total_amount) FILTER (WHERE NOT is_sale)                      AS non_sale_amount,    -- lo que quedó afuera
    ROUND(SUM(sales_amount)     / NULLIF(SUM(sale_count), 0), 2)      AS ticket_amount,      -- con IVA
    ROUND(SUM(sales_net_amount) / NULLIF(SUM(sale_count), 0), 2)      AS ticket_net_amount,  -- sin IVA
    ROUND((SUM(sales_amount) - SUM(shipping_fee) FILTER (WHERE is_sale))
          / NULLIF(SUM(sale_count), 0), 2)                            AS ticket_no_shipping  -- con IVA, sin envío
FROM order_periods
GROUP BY period_type, period, CUBE (channel, province)
ORDER BY period_type, period, channel, province;


-- ---------------------------------------------------------------------
-- mart_order_status — un período x canal x provincia x estado
-- ---------------------------------------------------------------------
-- Justifica la pregunta 2: cuántos pedidos hay en cada estado y cuáles
-- cuentan como venta (regla de dim_order_status.is_sale).

CREATE TABLE mart_order_status AS
SELECT
    o.period_type,
    o.period,
    COALESCE(o.channel,  'Todos')   AS channel,
    COALESCE(o.province, 'Todas')   AS province,
    s.status_code,
    s.description                   AS status_description,
    s.is_sale,
    COUNT(*)                        AS orders,
    SUM(o.total_amount)             AS total_amount
FROM order_periods AS o
JOIN dim_order_status AS s ON s.order_status_key = o.order_status_key
GROUP BY o.period_type, o.period, CUBE (o.channel, o.province),
         s.status_code, s.description, s.is_sale
ORDER BY o.period_type, o.period, channel, province, s.status_code;


-- Control: los marts cuadran con el modelo estrella (todo TRUE)
SELECT
    (SELECT sales_amount FROM mart_sales_kpi
      WHERE period = 'Todo' AND channel = 'Todos' AND province = 'Todas')
      = (SELECT SUM(sales_amount) FROM fact_sales_order)                            AS ventas_ok,
    (SELECT sale_orders FROM mart_sales_kpi
      WHERE period = 'Todo' AND channel = 'Todos' AND province = 'Todas')
      = (SELECT COUNT(*) FROM fact_sales_order WHERE is_sale)                       AS pedidos_ok,
    (SELECT SUM(sales_amount) FROM mart_sales_kpi
      WHERE period_type = 'month' AND channel = 'Todos' AND province = 'Todas')
      = (SELECT SUM(sales_amount) FROM fact_sales_order)                            AS meses_suman_total_ok,
    (SELECT SUM(orders) FROM mart_order_status
      WHERE period = 'Todo' AND channel = 'Todos' AND province = 'Todas')
      = (SELECT COUNT(*) FROM fact_sales_order)                                     AS estados_ok;

-- Las respuestas, tal como las va a mostrar el tablero
SELECT channel, sales_amount, sales_net_amount, sale_orders, ticket_amount, ticket_net_amount, ticket_no_shipping
FROM mart_sales_kpi
WHERE period = 'Todo' AND province = 'Todas'
ORDER BY channel;
