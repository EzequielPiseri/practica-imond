-- =====================================================================
-- 04_looker.sql — Capa de presentación para Looker Studio
-- =====================================================================
-- Looker Studio no maneja relaciones entre tablas como Power BI: cada CSV
-- es una "fuente de datos" independiente. Por eso, a partir del modelo
-- estrella, se arman tablas PLANAS: cada hecho con los atributos de sus
-- dimensiones ya unidos (fecha, canal, provincia, producto).
--
-- No reemplazan al modelo estrella: se derivan de él y solo existen para
-- que el tablero sea simple. Si cambia una regla, se cambia en 01/02 y
-- estas tablas la heredan.
--
-- Convenciones para que los filtros de Looker funcionen entre fuentes:
--   * Mismos nombres de columna en todas las tablas: fecha, canal,
--     provincia, producto. Looker aplica un control de filtro a todas
--     las fuentes que tienen un campo con el mismo nombre.
--   * Fechas como texto AAAAMMDD (20240102): es el formato que Looker
--     reconoce sin ambigüedad. Con AAAA-MM-DD interpretaba mal las fechas
--     de 2024 y el filtro de período las dejaba afuera.
--   * Indicadores numéricos 1/0 (es_venta, es_promotor...) en vez de
--     booleanos, para poder sumarlos en los campos calculados.
-- =====================================================================


-- ---------------------------------------------------------------------
-- looker_ventas — un pedido (tarjetas Ventas y Ticket, Ventas por Provincia)
-- ---------------------------------------------------------------------
CREATE TABLE looker_ventas AS
SELECT
    f.order_id                         AS pedido_id,
    strftime(d.date, '%Y%m%d')         AS fecha,     -- AAAAMMDD: formato nativo de Looker
    strftime(d.month_start, '%Y%m%d')  AS mes,
    c.code                             AS canal,
    s.name                             AS tienda,
    p.name                             AS provincia,
    p.iso_code                         AS provincia_iso,     -- AR-B, AR-X... para el mapa
    st.status_code                     AS estado,
    m.description                      AS medio_pago,
    CASE WHEN f.is_sale THEN 1 ELSE 0 END AS es_venta,
    f.units                            AS unidades,
    f.total_amount                     AS monto_total,
    f.sales_amount                     AS monto_venta        -- total si es venta, si no 0
FROM fact_sales_order    AS f
JOIN dim_date            AS d  ON d.date_key            = f.order_date_key
JOIN dim_channel         AS c  ON c.channel_key         = f.channel_key
JOIN dim_store           AS s  ON s.store_key           = f.store_key
JOIN dim_province        AS p  ON p.province_key        = f.province_key
JOIN dim_order_status    AS st ON st.order_status_key   = f.order_status_key
JOIN dim_payment_method  AS m  ON m.payment_method_key  = f.payment_method_key;


-- ---------------------------------------------------------------------
-- looker_productos — una línea de pedido (Ranking mensual por producto)
-- ---------------------------------------------------------------------
CREATE TABLE looker_productos AS
SELECT
    i.order_item_id                    AS linea_id,
    i.order_id                         AS pedido_id,
    strftime(d.date, '%Y%m%d')         AS fecha,     -- AAAAMMDD: formato nativo de Looker
    strftime(d.month_start, '%Y%m%d')  AS mes,
    c.code                             AS canal,
    p.name                             AS provincia,
    pr.name                            AS producto,
    pr.category                        AS categoria,
    CASE WHEN i.is_sale THEN 1 ELSE 0 END AS es_venta,
    i.quantity                         AS unidades,
    i.line_total                       AS monto_linea,
    i.sales_line_total                 AS monto_venta_linea  -- sin IVA ni envío
FROM fact_sales_order_item AS i
JOIN dim_date      AS d  ON d.date_key      = i.order_date_key
JOIN dim_channel   AS c  ON c.channel_key   = i.channel_key
JOIN dim_province  AS p  ON p.province_key  = i.province_key
JOIN dim_product   AS pr ON pr.product_key  = i.product_key;


-- ---------------------------------------------------------------------
-- looker_sesiones — una visita web (Usuarios Activos)
-- ---------------------------------------------------------------------
-- No tiene canal ni provincia: toda visita es web y no tiene ubicación.
-- Por eso esos filtros no afectan a Usuarios Activos (ver README).
-- cliente_id queda vacío en las visitas anónimas.

CREATE TABLE looker_sesiones AS
SELECT
    w.session_id                       AS sesion_id,
    strftime(d.date, '%Y%m%d')         AS fecha,     -- AAAAMMDD: formato nativo de Looker
    strftime(d.month_start, '%Y%m%d')  AS mes,
    dc.customer_id                     AS cliente_id,
    CASE WHEN w.is_logged_in THEN 1 ELSE 0 END AS logueado,
    t.description                      AS origen,
    dv.description                     AS dispositivo,
    w.duration_seconds                 AS duracion_segundos
FROM fact_web_session    AS w
JOIN dim_date            AS d  ON d.date_key            = w.date_key
JOIN dim_customer        AS dc ON dc.customer_key       = w.customer_key
JOIN dim_traffic_source  AS t  ON t.traffic_source_key  = w.traffic_source_key
JOIN dim_device          AS dv ON dv.device_key         = w.device_key;


-- ---------------------------------------------------------------------
-- looker_nps — una respuesta de la encuesta (NPS)
-- ---------------------------------------------------------------------
CREATE TABLE looker_nps AS
SELECT
    n.nps_id                           AS respuesta_id,
    strftime(d.date, '%Y%m%d')         AS fecha,     -- AAAAMMDD: formato nativo de Looker
    strftime(d.month_start, '%Y%m%d')  AS mes,
    c.code                             AS canal,
    dc.province_name                   AS provincia,         -- provincia del cliente (vacía si anónimo)
    n.score                            AS puntaje,
    n.nps_group                        AS grupo_nps,
    n.is_promoter                      AS es_promotor,
    n.is_passive                       AS es_pasivo,
    n.is_detractor                     AS es_detractor,
    n.comment                          AS comentario
FROM fact_nps_response AS n
JOIN dim_date          AS d  ON d.date_key      = n.date_key
JOIN dim_channel       AS c  ON c.channel_key   = n.channel_key
JOIN dim_customer      AS dc ON dc.customer_key = n.customer_key;


-- Control: las tablas planas tienen las mismas filas que sus hechos
SELECT 'looker_ventas' AS tabla, (SELECT COUNT(*) FROM looker_ventas) AS filas, (SELECT COUNT(*) FROM fact_sales_order) AS hecho
UNION ALL SELECT 'looker_productos', (SELECT COUNT(*) FROM looker_productos), (SELECT COUNT(*) FROM fact_sales_order_item)
UNION ALL SELECT 'looker_sesiones',  (SELECT COUNT(*) FROM looker_sesiones),  (SELECT COUNT(*) FROM fact_web_session)
UNION ALL SELECT 'looker_nps',       (SELECT COUNT(*) FROM looker_nps),       (SELECT COUNT(*) FROM fact_nps_response);
