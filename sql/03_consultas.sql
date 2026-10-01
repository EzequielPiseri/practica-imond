-- =====================================================================
-- 03_consultas.sql — Validaciones del modelo y consultas de KPIs
-- =====================================================================
-- Parte A: validaciones (el modelo cuadra contra raw/).
-- Parte B: los 6 KPIs del tablero, calculados desde el modelo estrella.
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


-- =====================================================================
-- PARTE B — KPIs DEL TABLERO
-- =====================================================================

-- B1. Tarjetas del período completo: Ventas ($M), Ticket ($K), Usuarios (nK), NPS
SELECT
    ROUND(SUM(f.sales_amount) / 1e6, 1)                                   AS ventas_millones,
    COUNT(*) FILTER (WHERE f.is_sale)                                     AS pedidos_validos,
    ROUND(SUM(f.sales_amount) / COUNT(*) FILTER (WHERE f.is_sale) / 1e3, 1) AS ticket_promedio_miles,
    (SELECT ROUND(COUNT(DISTINCT customer_key) / 1e3, 2)
       FROM fact_web_session WHERE customer_key <> -1)                    AS usuarios_activos_miles,
    (SELECT ROUND((SUM(is_promoter) - SUM(is_detractor)) * 100.0 / COUNT(*), 1)
       FROM fact_nps_response)                                            AS nps
FROM fact_sales_order AS f;

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

-- B6. Ranking mensual por producto (desde el agregado)
SELECT
    d.year_month,
    a.rank_in_month                       AS puesto,
    p.name                                AS producto,
    a.units                               AS unidades,
    ROUND(a.sales_amount / 1e6, 2)        AS ventas_millones,
    ROUND(a.share_of_month * 100, 1)      AS participacion_pct
FROM agg_sales_product_month AS a
JOIN dim_date    AS d ON d.date_key    = a.month_date_key
JOIN dim_product AS p ON p.product_key = a.product_key
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
