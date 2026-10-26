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
--
-- Tablas que genera:
--   mart_sales_kpi      ventas, pedidos y ticket   período x canal x provincia
--   mart_order_status   pedidos por estado         período x canal x provincia x estado
--   mart_sales_product  ventas por producto        período x canal x provincia x producto
--   mart_customer_kpi   usuarios activos, sesiones período
--   mart_session_mix    sesiones por origen y dispositivo
--   mart_nps_kpi        NPS                        período x canal
--   mart_nps_group      respuestas por grupo NPS   período x canal x grupo
--   mart_growth         ene-sep 2024 vs ene-sep 2025, una fila por KPI
--   mart_dim_period / mart_dim_channel / mart_dim_province
--                       valores de cada filtro, para las segmentaciones
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


-- =====================================================================
-- Marts para Power BI: el resto de los KPIs del tablero
-- =====================================================================
-- Misma idea que mart_sales_kpi: una fila por período (y canal, cuando
-- corresponde), con el KPI ya calculado. Power BI solo muestra la fila.

-- Base de períodos por fecha: cada fecha en sus tres períodos
CREATE TEMP VIEW date_periods AS
SELECT date_key, 'total' AS period_type, 'Todo'                AS period FROM dim_date
UNION ALL
SELECT date_key, 'year',                 CAST(year AS VARCHAR)           FROM dim_date
UNION ALL
SELECT date_key, 'month',                year_month                      FROM dim_date;


-- ---------------------------------------------------------------------
-- Tablas de filtro: una fila por valor de cada segmentación
-- ---------------------------------------------------------------------
-- En Power BI se relacionan 1 a N con cada mart (por period, channel o
-- province) y las segmentaciones se arman sobre estas tablas. Así un
-- mismo filtro afecta a todos los marts que tienen esa columna, y a los
-- que no la tienen (usuarios no tiene canal ni provincia) no los toca.

CREATE TABLE mart_dim_period AS
WITH periods AS (
    SELECT DISTINCT 'total' AS period_type, 'Todo' AS period,
           'Todo el período' AS period_label, NULL::DATE AS period_start
    UNION ALL
    SELECT DISTINCT 'year', CAST(year AS VARCHAR), CAST(year AS VARCHAR), make_date(year, 1, 1)
    FROM dim_date
    WHERE year_month IN (SELECT period FROM mart_sales_kpi WHERE period_type = 'month')
    UNION ALL
    SELECT DISTINCT 'month', year_month, month_name || ' ' || year, month_start
    FROM dim_date
    WHERE year_month IN (SELECT period FROM mart_sales_kpi WHERE period_type = 'month')
)
SELECT
    period,
    period_type,
    period_label,
    period_start,                                                   -- eje de fechas de las series
    ROW_NUMBER() OVER (ORDER BY CASE period_type WHEN 'total' THEN 0 WHEN 'year' THEN 1 ELSE 2 END,
                                period) AS sort_order               -- "Ordenar por columna" en Power BI
FROM periods
ORDER BY sort_order;

CREATE TABLE mart_dim_channel AS
SELECT * FROM (VALUES
    ('Todos',   'Todos',           1),
    ('ONLINE',  'Tienda online',   2),
    ('OFFLINE', 'Tiendas físicas', 3)
) AS t (channel, channel_label, sort_order);

CREATE TABLE mart_dim_province AS
SELECT
    province,
    ROW_NUMBER() OVER (ORDER BY province <> 'Todas', province) AS sort_order
FROM (SELECT DISTINCT province FROM mart_sales_kpi)
ORDER BY sort_order;


-- ---------------------------------------------------------------------
-- mart_sales_product — período x canal x provincia x producto
-- ---------------------------------------------------------------------
-- Ventas de línea (sin IVA ni envío) de los pedidos que son venta, con el
-- ranking del producto dentro de cada combinación de filtros.

CREATE TABLE mart_sales_product AS
WITH items AS (
    SELECT dp.period_type, dp.period, c.code AS channel, p.name AS province,
           pr.name AS product, i.quantity, i.line_total
    FROM fact_sales_order_item AS i
    JOIN date_periods AS dp ON dp.date_key     = i.order_date_key
    JOIN dim_channel  AS c  ON c.channel_key   = i.channel_key
    JOIN dim_province AS p  ON p.province_key  = i.province_key
    JOIN dim_product  AS pr ON pr.product_key  = i.product_key
    WHERE i.is_sale
),
grouped AS (
    SELECT
        period_type,
        period,
        COALESCE(channel,  'Todos') AS channel,
        COALESCE(province, 'Todas') AS province,
        product,
        SUM(quantity)               AS units,
        SUM(line_total)             AS sales_line_amount
    FROM items
    GROUP BY period_type, period, CUBE (channel, province), product
)
SELECT
    *,
    RANK() OVER w                                                      AS rank_in_period,  -- 1 = el que más vendió en $
    ROUND(sales_line_amount / SUM(sales_line_amount) OVER w_all, 4)    AS share_of_period
FROM grouped
WINDOW w     AS (PARTITION BY period, channel, province ORDER BY sales_line_amount DESC),
       w_all AS (PARTITION BY period, channel, province)
ORDER BY period_type, period, channel, province, product;


-- ---------------------------------------------------------------------
-- mart_customer_kpi — un período
-- ---------------------------------------------------------------------
-- Usuarios activos = clientes distintos con al menos una sesión logueada.
-- Un recuento distinto no se puede sumar entre meses (el mismo cliente
-- puede entrar en varios), por eso se calcula para cada período.
-- Sin canal ni provincia: todas las visitas son web y no tienen ubicación.

CREATE TABLE mart_customer_kpi AS
SELECT
    dp.period_type,
    dp.period,
    COUNT(DISTINCT w.active_customer_key)                          AS active_users,
    COUNT(*)                                                       AS sessions,
    COUNT(*) FILTER (WHERE w.is_logged_in)                         AS logged_sessions,
    ROUND(COUNT(*) FILTER (WHERE w.is_logged_in) * 1.0 / COUNT(*), 4) AS logged_share
FROM fact_web_session AS w
JOIN date_periods AS dp ON dp.date_key = w.date_key
GROUP BY dp.period_type, dp.period
ORDER BY dp.period_type, dp.period;


-- ---------------------------------------------------------------------
-- mart_session_mix — período x tipo de apertura x valor
-- ---------------------------------------------------------------------
-- Sesiones por origen de tráfico y por dispositivo, con su participación.

CREATE TABLE mart_session_mix AS
WITH sessions AS (
    SELECT dp.period_type, dp.period, 'Origen' AS breakdown, ts.description AS label
    FROM fact_web_session AS w
    JOIN date_periods       AS dp ON dp.date_key            = w.date_key
    JOIN dim_traffic_source AS ts ON ts.traffic_source_key  = w.traffic_source_key
    UNION ALL
    SELECT dp.period_type, dp.period, 'Dispositivo', dv.description
    FROM fact_web_session AS w
    JOIN date_periods AS dp ON dp.date_key   = w.date_key
    JOIN dim_device   AS dv ON dv.device_key = w.device_key
)
SELECT
    period_type,
    period,
    breakdown,
    label,
    COUNT(*)                                                                    AS sessions,
    ROUND(COUNT(*) * 1.0 / SUM(COUNT(*)) OVER (PARTITION BY period, breakdown), 4) AS share
FROM sessions
GROUP BY period_type, period, breakdown, label
ORDER BY period_type, period, breakdown, sessions DESC;


-- ---------------------------------------------------------------------
-- mart_nps_kpi — período x canal (con total)
-- ---------------------------------------------------------------------
-- NPS = %promotores - %detractores = promedio de nps_points.
-- Sin provincia: la encuesta no tiene pedido, no hay provincia de venta.

CREATE TABLE mart_nps_kpi AS
SELECT
    dp.period_type,
    dp.period,
    COALESCE(c.code, 'Todos')                                      AS channel,
    COUNT(*)                                                       AS responses,
    SUM(n.is_promoter)                                             AS promoters,
    SUM(n.is_passive)                                              AS passives,
    SUM(n.is_detractor)                                            AS detractors,
    ROUND(SUM(n.is_promoter)  * 1.0 / COUNT(*), 4)                 AS promoter_share,
    ROUND(SUM(n.is_detractor) * 1.0 / COUNT(*), 4)                 AS detractor_share,
    ROUND(AVG(n.nps_points), 1)                                    AS nps
FROM fact_nps_response AS n
JOIN date_periods AS dp ON dp.date_key    = n.date_key
JOIN dim_channel  AS c  ON c.channel_key  = n.channel_key
GROUP BY dp.period_type, dp.period, CUBE (c.code)
ORDER BY dp.period_type, dp.period, channel;

-- Lo mismo en formato largo (una fila por grupo), para el gráfico de anillo
CREATE TABLE mart_nps_group AS
SELECT
    k.period_type,
    k.period,
    k.channel,
    g.nps_group,
    g.sort_order,
    g.responses,
    ROUND(g.responses * 1.0 / k.responses, 4)                      AS share
FROM mart_nps_kpi AS k
CROSS JOIN LATERAL (
    VALUES ('Promotor', 1, k.promoters), ('Pasivo', 2, k.passives), ('Detractor', 3, k.detractors)
) AS g (nps_group, sort_order, responses)
ORDER BY k.period_type, k.period, k.channel, g.sort_order;


-- ---------------------------------------------------------------------
-- mart_growth — enero a septiembre 2024 contra enero a septiembre 2025
-- ---------------------------------------------------------------------
-- Reemplaza la comparación contra el año anterior: compara períodos
-- equivalentes (2025 termina en septiembre). Una fila por KPI, con el
-- valor de cada año, la variación y el texto ya formateado para mostrar.

CREATE TEMP MACRO fmt_num(x, decimals) AS
    translate(format('{:,.' || decimals || 'f}', x), ',.', '.,');

CREATE TABLE mart_growth AS
WITH sales AS (
    SELECT
        d.year,
        SUM(f.sales_amount)                                                  AS ventas,
        SUM(f.sales_net_amount)                                              AS ventas_sin_iva,
        SUM(f.sale_count)                                                    AS pedidos,
        SUM(f.sales_amount) / SUM(f.sale_count)                              AS ticket,
        COUNT(DISTINCT f.customer_key) FILTER (WHERE f.is_sale AND f.customer_key <> -1) AS clientes,
        SUM(f.sales_amount) FILTER (WHERE c.code = 'ONLINE')                 AS ventas_online,
        SUM(f.sales_amount) FILTER (WHERE c.code = 'OFFLINE')                AS ventas_offline
    FROM fact_sales_order AS f
    JOIN dim_date    AS d ON d.date_key    = f.order_date_key
    JOIN dim_channel AS c ON c.channel_key = f.channel_key
    WHERE d.month <= 9
    GROUP BY d.year
),
users AS (
    SELECT d.year, COUNT(DISTINCT w.active_customer_key) AS usuarios
    FROM fact_web_session AS w
    JOIN dim_date AS d ON d.date_key = w.date_key
    WHERE d.month <= 9
    GROUP BY d.year
),
nps AS (
    SELECT d.year, AVG(n.nps_points) AS nps
    FROM fact_nps_response AS n
    JOIN dim_date AS d ON d.date_key = n.date_key
    WHERE d.month <= 9
    GROUP BY d.year
),
by_year AS (
    SELECT * FROM sales JOIN users USING (year) JOIN nps USING (year)
),
kpis AS (
    -- sort_order, kpi, unidad, valor 2024, valor 2025
    SELECT 1, 'Ventas con IVA',              'money', a.ventas,         b.ventas         FROM by_year a, by_year b WHERE a.year = 2024 AND b.year = 2025
    UNION ALL
    SELECT 2, 'Ventas sin IVA',              'money', a.ventas_sin_iva, b.ventas_sin_iva FROM by_year a, by_year b WHERE a.year = 2024 AND b.year = 2025
    UNION ALL
    SELECT 3, 'Ventas tienda online',        'money', a.ventas_online,  b.ventas_online  FROM by_year a, by_year b WHERE a.year = 2024 AND b.year = 2025
    UNION ALL
    SELECT 4, 'Ventas tiendas físicas',      'money', a.ventas_offline, b.ventas_offline FROM by_year a, by_year b WHERE a.year = 2024 AND b.year = 2025
    UNION ALL
    SELECT 5, 'Pedidos válidos',             'count', a.pedidos,        b.pedidos        FROM by_year a, by_year b WHERE a.year = 2024 AND b.year = 2025
    UNION ALL
    SELECT 6, 'Clientes que compraron',      'count', a.clientes,       b.clientes       FROM by_year a, by_year b WHERE a.year = 2024 AND b.year = 2025
    UNION ALL
    SELECT 7, 'Ticket promedio (con IVA)',   'ticket', a.ticket,        b.ticket         FROM by_year a, by_year b WHERE a.year = 2024 AND b.year = 2025
    UNION ALL
    SELECT 8, 'Usuarios activos',            'count', a.usuarios,       b.usuarios       FROM by_year a, by_year b WHERE a.year = 2024 AND b.year = 2025
    UNION ALL
    SELECT 9, 'NPS',                         'score', a.nps,            b.nps            FROM by_year a, by_year b WHERE a.year = 2024 AND b.year = 2025
),
calc AS (
    SELECT
        col0 AS sort_order, col1 AS kpi, col2 AS unit,
        ROUND(col3, 2) AS value_2024,
        ROUND(col4, 2) AS value_2025,
        -- El NPS ya es un puntaje: su variación va en puntos, no en %
        CASE WHEN col2 = 'score' THEN ROUND(col4 - col3, 1)
             ELSE ROUND((col4 - col3) * 100.0 / col3, 1) END AS change
    FROM kpis AS k (col0, col1, col2, col3, col4)
)
SELECT
    sort_order,
    kpi,
    value_2024,
    value_2025,
    change,
    CASE WHEN unit = 'score' THEN 'puntos' ELSE '%' END            AS change_unit,
    -- Texto listo para mostrar (formato argentino: punto de miles, coma decimal)
    CASE unit
        WHEN 'money'  THEN '$' || fmt_num(value_2024 / 1e6, 1) || ' M'
        WHEN 'ticket' THEN '$' || fmt_num(value_2024, 0)
        WHEN 'score'  THEN fmt_num(value_2024, 1)
        ELSE fmt_num(value_2024, 0) END                            AS label_2024,
    CASE unit
        WHEN 'money'  THEN '$' || fmt_num(value_2025 / 1e6, 1) || ' M'
        WHEN 'ticket' THEN '$' || fmt_num(value_2025, 0)
        WHEN 'score'  THEN fmt_num(value_2025, 1)
        ELSE fmt_num(value_2025, 0) END                            AS label_2025,
    CASE WHEN change > 0 THEN '▲ +' WHEN change < 0 THEN '▼ ' ELSE '' END
        || fmt_num(change, 1)
        || CASE WHEN unit = 'score' THEN ' pts' ELSE ' %' END      AS label_change,
    -- Color para el formato condicional ("Valor del campo"): ±1 = estable
    CASE WHEN change >  1 THEN '#2E7D4F'
         WHEN change < -1 THEN '#C0392B'
         ELSE '#C8842A' END                                        AS change_color
FROM calc
ORDER BY sort_order;


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
      = (SELECT COUNT(*) FROM fact_sales_order)                                     AS estados_ok,
    (SELECT SUM(sales_line_amount) FROM mart_sales_product
      WHERE period = 'Todo' AND channel = 'Todos' AND province = 'Todas')
      = (SELECT SUM(sales_line_total) FROM fact_sales_order_item)                   AS productos_ok,
    (SELECT active_users FROM mart_customer_kpi WHERE period = 'Todo')
      = (SELECT COUNT(DISTINCT active_customer_key) FROM fact_web_session)          AS usuarios_ok,
    (SELECT SUM(sessions) FROM mart_session_mix WHERE period = 'Todo' AND breakdown = 'Origen')
      = (SELECT COUNT(*) FROM fact_web_session)                                     AS sesiones_ok,
    (SELECT nps FROM mart_nps_kpi WHERE period = 'Todo' AND channel = 'Todos')
      = (SELECT ROUND(AVG(nps_points), 1) FROM fact_nps_response)                   AS nps_ok,
    (SELECT SUM(responses) FROM mart_nps_group WHERE period = 'Todo' AND channel = 'Todos')
      = (SELECT COUNT(*) FROM fact_nps_response)                                    AS nps_grupos_ok;

-- Las respuestas, tal como las va a mostrar el tablero
SELECT channel, sales_amount, sales_net_amount, sale_orders, ticket_amount, ticket_net_amount, ticket_no_shipping
FROM mart_sales_kpi
WHERE period = 'Todo' AND province = 'Todas'
ORDER BY channel;
