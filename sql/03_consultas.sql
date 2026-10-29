-- =====================================================================
-- 03_consultas.sql — Validaciones del modelo y consultas de KPIs
-- =====================================================================
-- Parte A: validaciones (el modelo cuadra contra raw/).
-- Parte B: los KPIs del tablero, calculados desde el modelo estrella con
--          las columnas de medida de 02_hechos.sql. Los mismos KPIs, ya
--          materializados por período, canal y provincia, están en
--          05_marts.sql.
-- Parte C: consultas exploratorias para hallazgos.
-- =====================================================================


-- =====================================================================
-- PARTE A — VALIDACIONES
-- =====================================================================

-- A1. Cada hecho tiene las mismas filas que su tabla de origen
SELECT 'fact_sales_order'      AS tabla, (SELECT COUNT(*) FROM fact_sales_order)      AS dw, (SELECT COUNT(*) FROM raw.sales_order)      AS raw
UNION ALL SELECT 'fact_sales_order_item', (SELECT COUNT(*) FROM fact_sales_order_item), (SELECT COUNT(*) FROM raw.sales_order_item)
UNION ALL SELECT 'fact_payment',          (SELECT COUNT(*) FROM fact_payment),          (SELECT COUNT(*) FROM raw.payment)
UNION ALL SELECT 'fact_shipment',         (SELECT COUNT(*) FROM fact_shipment),         (SELECT COUNT(*) FROM raw.shipment)
UNION ALL SELECT 'fact_web_session',      (SELECT COUNT(*) FROM fact_web_session),      (SELECT COUNT(*) FROM raw.web_session)
UNION ALL SELECT 'fact_nps_response',     (SELECT COUNT(*) FROM fact_nps_response),     (SELECT COUNT(*) FROM raw.nps_response);

-- A2. Las ventas del modelo coinciden con calcularlas directo sobre raw/
SELECT
    (SELECT SUM(sales_amount) FROM fact_sales_order)                     AS ventas_dw,
    (SELECT SUM(total_amount) FROM raw.sales_order
      WHERE status IN ('PAID', 'FULFILLED'))                             AS ventas_raw;

-- A3. Ningún hecho quedó con miembros "desconocidos" inesperados
SELECT
    (SELECT COUNT(*) FROM fact_sales_order  WHERE province_key = -1)    AS pedidos_sin_provincia,
    (SELECT COUNT(*) FROM fact_sales_order  WHERE customer_key = -1)    AS pedidos_sin_cliente,
    (SELECT COUNT(*) FROM fact_web_session  WHERE customer_key = -1)    AS sesiones_anonimas,
    (SELECT COUNT(*) FROM fact_nps_response WHERE customer_key = -1)    AS nps_anonimos;

-- A4. Las líneas suman el subtotal de cada pedido (0 = todo cuadra)
SELECT COUNT(*) AS pedidos_descuadrados
FROM fact_sales_order AS f
JOIN (SELECT order_id, SUM(line_total) AS s FROM fact_sales_order_item GROUP BY order_id) AS i
  USING (order_id)
WHERE i.s <> f.subtotal;

-- A5. Las columnas de medida dan lo mismo que las fórmulas de cada KPI,
--     en total y por canal (todo TRUE)
SELECT
    c.code                                                                        AS canal,
    SUM(f.sale_count) = COUNT(*) FILTER (WHERE f.is_sale)                         AS pedidos_ok,
    ABS(AVG(f.ticket_amount) - SUM(f.sales_amount) / SUM(f.sale_count)) < 0.01    AS ticket_ok,
    SUM(f.sales_net_amount) = SUM(f.sales_amount) - SUM(f.tax_amount) FILTER (WHERE f.is_sale) AS ventas_sin_iva_ok,
    (SELECT ABS(AVG(n.nps_points)
                - (SUM(n.is_promoter) - SUM(n.is_detractor)) * 100.0 / COUNT(*)) < 0.0001
       FROM fact_nps_response AS n WHERE n.channel_key = c.channel_key)           AS nps_ok
FROM fact_sales_order AS f
JOIN dim_channel AS c ON c.channel_key = f.channel_key
GROUP BY c.code, c.channel_key
ORDER BY canal;


-- =====================================================================
-- PARTE B — KPIs DEL TABLERO
-- =====================================================================

-- B1. Tarjetas del período completo, con las columnas de medida
SELECT
    ROUND(SUM(f.sales_amount) / 1e6, 1)                     AS ventas_millones,          -- SUMA
    ROUND(SUM(f.sales_net_amount) / 1e6, 1)                 AS ventas_sin_iva_millones,  -- SUMA
    SUM(f.sale_count)                                       AS pedidos_validos,          -- SUMA
    ROUND(AVG(f.ticket_amount) / 1e3, 1)                    AS ticket_miles,             -- PROMEDIO
    ROUND(AVG(f.ticket_net_amount) / 1e3, 1)                AS ticket_sin_iva_miles,     -- PROMEDIO
    (SELECT ROUND(COUNT(DISTINCT active_customer_key) / 1e3, 2)
       FROM fact_web_session)                               AS usuarios_activos_miles,   -- RECUENTO DISTINTO
    (SELECT ROUND(AVG(nps_points), 1) FROM fact_nps_response) AS nps                     -- PROMEDIO
FROM fact_sales_order AS f;

-- B1b. Desglose de la venta: de la venta neta de producto al total cobrado
SELECT
    ROUND(SUM(subtotal)         / 1e6, 1) AS subtotal_productos_millones,
    ROUND(SUM(tax_amount)       / 1e6, 1) AS iva_millones,
    ROUND(SUM(shipping_fee)     / 1e6, 1) AS envio_millones,
    ROUND(SUM(sales_net_amount) / 1e6, 1) AS ventas_sin_iva_millones,   -- subtotal + envío
    ROUND(SUM(sales_amount)     / 1e6, 1) AS ventas_con_iva_millones    -- subtotal + IVA + envío
FROM fact_sales_order
WHERE is_sale;

-- B2. Serie mensual: ventas, pedidos y ticket promedio, por canal
SELECT
    d.year_month,
    c.code                                                     AS canal,
    ROUND(SUM(f.sales_amount) / 1e6, 2)                        AS ventas_millones,
    COUNT(*) FILTER (WHERE f.is_sale)                          AS pedidos,
    ROUND(SUM(f.sales_amount) / COUNT(*) FILTER (WHERE f.is_sale), 0) AS ticket_promedio
FROM fact_sales_order AS f
JOIN dim_date    AS d ON d.date_key    = f.order_date_key
JOIN dim_channel AS c ON c.channel_key = f.channel_key
GROUP BY ALL
ORDER BY d.year_month, canal;

-- B3. Usuarios activos por mes (clientes logueados distintos) y sesiones
SELECT
    d.year_month,
    COUNT(DISTINCT w.customer_key) FILTER (WHERE w.is_logged_in) AS usuarios_activos,
    COUNT(*)                                                     AS sesiones,
    ROUND(AVG(w.is_logged_in::INT) * 100, 1)                     AS pct_sesiones_logueadas
FROM fact_web_session AS w
JOIN dim_date AS d ON d.date_key = w.date_key
GROUP BY ALL
ORDER BY d.year_month;

-- B3b. Usuarios activos: las dos formas de contarlos
-- El KPI del tablero cuenta clientes logueados distintos. La consigna
-- sugiere sumar además las sesiones anónimas: se muestra para comparar,
-- pero mezcla personas con visitas (un anónimo que vuelve 10 veces cuenta 10).
SELECT
    COUNT(DISTINCT active_customer_key)                         AS clientes_identificados,
    COUNT(*) FILTER (WHERE active_customer_key IS NULL)         AS sesiones_anonimas,
    COUNT(DISTINCT active_customer_key)
      + COUNT(*) FILTER (WHERE active_customer_key IS NULL)     AS total_combinado
FROM fact_web_session;

-- B4. NPS por mes y canal
SELECT
    d.year_month,
    c.code                                                             AS canal,
    COUNT(*)                                                           AS respuestas,
    ROUND((SUM(n.is_promoter) - SUM(n.is_detractor)) * 100.0 / COUNT(*), 1) AS nps
FROM fact_nps_response AS n
JOIN dim_date    AS d ON d.date_key    = n.date_key
JOIN dim_channel AS c ON c.channel_key = n.channel_key
GROUP BY d.year_month, c.code
ORDER BY d.year_month, canal;

-- B5. Ventas por provincia (con participación)
SELECT
    p.name                                                          AS provincia,
    ROUND(SUM(f.sales_amount) / 1e6, 2)                             AS ventas_millones,
    ROUND(SUM(f.sales_amount) * 100.0 / SUM(SUM(f.sales_amount)) OVER (), 1) AS participacion_pct
FROM fact_sales_order AS f
JOIN dim_province AS p ON p.province_key = f.province_key
GROUP BY ALL
ORDER BY ventas_millones DESC;

-- B6. Ranking mensual por producto (ventas de línea, sin IVA ni envío)
SELECT
    d.year_month,
    RANK() OVER (PARTITION BY d.year_month ORDER BY SUM(i.line_total) DESC) AS puesto,
    p.name                                                          AS producto,
    SUM(i.quantity)                                                 AS unidades,
    ROUND(SUM(i.line_total) / 1e6, 2)                               AS ventas_millones,
    ROUND(SUM(i.line_total) * 100.0
          / SUM(SUM(i.line_total)) OVER (PARTITION BY d.year_month), 1) AS participacion_pct
FROM fact_sales_order_item AS i
JOIN dim_date    AS d ON d.date_key    = i.order_date_key
JOIN dim_product AS p ON p.product_key = i.product_key
WHERE i.is_sale
GROUP BY d.year_month, p.name
ORDER BY d.year_month, puesto;


-- =====================================================================
-- PARTE C — EXPLORACIÓN PARA HALLAZGOS
-- =====================================================================

-- C1. ¿Cuánta plata se pierde por cancelaciones y reembolsos?
SELECT
    s.status_code,
    COUNT(*)                               AS pedidos,
    ROUND(SUM(f.total_amount) / 1e6, 2)    AS monto_millones,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct_pedidos
FROM fact_sales_order AS f
JOIN dim_order_status AS s ON s.order_status_key = f.order_status_key
GROUP BY ALL
ORDER BY pedidos DESC;

-- C2. Tasa de rechazo de pago por medio de pago
SELECT
    m.description                                          AS medio_pago,
    COUNT(*)                                               AS pagos,
    ROUND(AVG((p.payment_status = 'FAILED')::INT) * 100, 1) AS pct_fallidos
FROM fact_payment AS p
JOIN dim_payment_method AS m ON m.payment_method_key = p.payment_method_key
GROUP BY ALL
ORDER BY pct_fallidos DESC;

-- C3. Tiempos de entrega por provincia (solo entregados)
SELECT
    pr.name                                    AS provincia,
    COUNT(*)                                   AS envios_entregados,
    ROUND(AVG(s.days_order_to_door), 1)        AS dias_promedio_a_la_puerta,
    ROUND(quantile_cont(s.days_order_to_door, 0.9), 1) AS p90_dias
FROM fact_shipment AS s
JOIN dim_province AS pr ON pr.province_key = s.province_key
WHERE s.shipment_status = 'DELIVERED'
GROUP BY ALL
ORDER BY dias_promedio_a_la_puerta DESC;

-- C4. Tráfico por origen: sesiones, % logueado y duración
SELECT
    t.description                                   AS origen,
    COUNT(*)                                        AS sesiones,
    ROUND(AVG(w.is_logged_in::INT) * 100, 1)        AS pct_logueadas,
    ROUND(AVG(w.duration_seconds) / 60, 1)          AS minutos_promedio
FROM fact_web_session AS w
JOIN dim_traffic_source AS t ON t.traffic_source_key = w.traffic_source_key
GROUP BY ALL
ORDER BY sesiones DESC;

-- C5. Mix de producto por canal
SELECT
    c.code                                         AS canal,
    p.name                                         AS producto,
    SUM(i.quantity)                                AS unidades,
    ROUND(SUM(i.sales_line_total) * 100.0
          / SUM(SUM(i.sales_line_total)) OVER (PARTITION BY c.code), 1) AS pct_del_canal
FROM fact_sales_order_item AS i
JOIN dim_channel AS c ON c.channel_key = i.channel_key
JOIN dim_product AS p ON p.product_key = i.product_key
WHERE i.is_sale
GROUP BY c.code, p.name
ORDER BY canal, unidades DESC;

-- C6. Distribución NPS por canal (promotores / pasivos / detractores)
SELECT
    c.code                                  AS canal,
    n.nps_group,
    COUNT(*)                                AS respuestas,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY c.code), 1) AS pct
FROM fact_nps_response AS n
JOIN dim_channel AS c ON c.channel_key = n.channel_key
GROUP BY c.code, n.nps_group
ORDER BY canal, n.nps_group;

-- C7. NPS online vs. demora de entrega, mes a mes
-- El NPS se toma por mes de respuesta y la demora por mes de entrega
-- (la encuesta llega 7 días después de recibir el pedido).
WITH nps_online AS (
    SELECT d.month_start                                   AS mes,
           COUNT(*)                                        AS respuestas,
           ROUND((SUM(n.is_promoter) - SUM(n.is_detractor)) * 100.0 / COUNT(*), 1) AS nps_online
    FROM fact_nps_response AS n
    JOIN dim_date    AS d ON d.date_key    = n.date_key
    JOIN dim_channel AS c ON c.channel_key = n.channel_key
    WHERE c.code = 'ONLINE'
    GROUP BY d.month_start
),
entregas AS (
    SELECT d.month_start                                   AS mes,
           COUNT(*)                                        AS envios_entregados,
           ROUND(AVG(s.days_to_deliver), 1)                AS dias_despacho_a_entrega
    FROM fact_shipment AS s
    JOIN dim_date AS d ON d.date_key = s.delivered_date_key
    WHERE s.shipment_status = 'DELIVERED'
    GROUP BY d.month_start
)
SELECT strftime(n.mes, '%Y-%m') AS mes, n.respuestas, n.nps_online,
       e.envios_entregados, e.dias_despacho_a_entrega
FROM nps_online AS n
LEFT JOIN entregas AS e ON e.mes = n.mes
ORDER BY n.mes;

-- C8. ¿El crecimiento viene de más compras o de compras más caras?
-- Mismo período en los dos años (enero a septiembre), porque 2025 termina en septiembre.
SELECT
    d.year                                              AS anio,
    ROUND(SUM(f.sales_amount) / 1e6, 1)                 AS ventas_millones,
    COUNT(*)                                            AS pedidos_validos,
    COUNT(DISTINCT f.customer_key) FILTER (WHERE f.customer_key <> -1) AS clientes_identificados,
    ROUND(SUM(f.sales_amount) / COUNT(*) / 1e3, 2)      AS ticket_miles
FROM fact_sales_order AS f
JOIN dim_date AS d ON d.date_key = f.order_date_key
WHERE f.is_sale AND d.month <= 9
GROUP BY d.year
ORDER BY d.year;

-- C9. Visitas por dispositivo
SELECT
    dv.description                                      AS dispositivo,
    COUNT(*)                                            AS sesiones,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1)  AS pct
FROM fact_web_session AS w
JOIN dim_device AS dv ON dv.device_key = w.device_key
GROUP BY dv.description
ORDER BY sesiones DESC;
