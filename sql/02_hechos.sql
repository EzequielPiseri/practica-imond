-- =====================================================================
-- 02_hechos.sql — Tablas de HECHOS del modelo estrella
-- =====================================================================
-- Se ejecuta después de 01_dimensiones.sql: los hechos apuntan a las
-- dimensiones con FOREIGN KEY, y DuckDB rechaza la carga si alguna
-- clave no existe (es la primera validación del modelo).
--
-- Hechos del modelo (una fila = ...):
--   fact_sales_order       un pedido                (KPIs: Ventas, Ticket, Provincia)
--   fact_sales_order_item  un producto en un pedido (KPI: Ranking por producto)
--   fact_payment           un pago
--   fact_shipment          un envío por correo
--   fact_web_session       una visita a la web      (KPI: Usuarios activos)
--   fact_nps_response      una respuesta NPS        (KPI: NPS)
--   agg_sales_product_month  agregado: producto x mes con ranking
--
-- Las claves de fechas opcionales (pago, envío, entrega) quedan NULL
-- cuando el evento todavía no ocurrió: un -1 ahí sería una fecha falsa.
-- =====================================================================


-- ---------------------------------------------------------------------
-- fact_sales_order — GRANO: un pedido
-- ---------------------------------------------------------------------
-- Provincia = la de la dirección de envío. En compras en tienda esa
-- dirección es la de la tienda (regla del README), así que cubre ambos
-- canales; las 240 ventas de tienda enviadas a domicilio cuentan en la
-- provincia del cliente.

CREATE TABLE fact_sales_order (
    order_id            BIGINT  PRIMARY KEY,                    -- dimensión degenerada
    order_date_key      INTEGER NOT NULL REFERENCES dim_date (date_key),
    customer_key        INTEGER NOT NULL REFERENCES dim_customer (customer_key),
    channel_key         INTEGER NOT NULL REFERENCES dim_channel (channel_key),
    store_key           INTEGER NOT NULL REFERENCES dim_store (store_key),
    province_key        INTEGER NOT NULL REFERENCES dim_province (province_key),
    order_status_key    INTEGER NOT NULL REFERENCES dim_order_status (order_status_key),
    payment_method_key  INTEGER NOT NULL REFERENCES dim_payment_method (payment_method_key),
    is_sale             BOOLEAN NOT NULL,      -- copia de dim_order_status.is_sale
    item_lines          INTEGER NOT NULL,
    units               INTEGER NOT NULL,
    subtotal            DECIMAL(12, 2) NOT NULL,
    discount_amount     DECIMAL(12, 2) NOT NULL,
    tax_amount          DECIMAL(12, 2) NOT NULL,
    shipping_fee        DECIMAL(12, 2) NOT NULL,
    total_amount        DECIMAL(12, 2) NOT NULL,
    sales_amount        DECIMAL(12, 2) NOT NULL   -- total_amount si is_sale, si no 0
);

INSERT INTO fact_sales_order
WITH items AS (
    SELECT order_id,
           COUNT(*)             AS item_lines,
           SUM(quantity)        AS units,
           SUM(discount_amount) AS discount_amount
    FROM raw.sales_order_item
    GROUP BY order_id
)
SELECT
    o.order_id,
    CAST(strftime(o.order_date, '%Y%m%d') AS INTEGER),
    COALESCE(dc.customer_key, -1),
    ch.channel_key,
    COALESCE(ds.store_key, -1),
    COALESCE(dp.province_key, -1),
    st.order_status_key,
    pm.payment_method_key,
    st.is_sale,
    i.item_lines,
    i.units,
    o.subtotal,
    i.discount_amount,
    o.tax_amount,
    o.shipping_fee,
    o.total_amount,
    CASE WHEN st.is_sale THEN o.total_amount ELSE 0 END
FROM raw.sales_order AS o
JOIN items                     AS i  ON i.order_id     = o.order_id
JOIN dim_channel               AS ch ON ch.channel_id  = o.channel_id
JOIN dim_order_status          AS st ON st.status_code = o.status
JOIN raw.payment               AS p  ON p.order_id     = o.order_id
JOIN dim_payment_method        AS pm ON pm.method_code = p.method
LEFT JOIN dim_customer         AS dc ON dc.customer_id = o.customer_id
LEFT JOIN dim_store            AS ds ON ds.store_id    = o.store_id
LEFT JOIN raw.address          AS a  ON a.address_id   = o.shipping_address_id
LEFT JOIN dim_province         AS dp ON dp.province_id = a.province_id;


-- ---------------------------------------------------------------------
-- fact_sales_order_item — GRANO: un producto dentro de un pedido
-- ---------------------------------------------------------------------
-- Repite las claves del pedido (fecha, canal, provincia...) para que el
-- ranking por producto se pueda filtrar igual que las ventas.

CREATE TABLE fact_sales_order_item (
    order_item_id     BIGINT  PRIMARY KEY,
    order_id          BIGINT  NOT NULL,                         -- dimensión degenerada
    order_date_key    INTEGER NOT NULL REFERENCES dim_date (date_key),
    product_key       INTEGER NOT NULL REFERENCES dim_product (product_key),
    customer_key      INTEGER NOT NULL REFERENCES dim_customer (customer_key),
    channel_key       INTEGER NOT NULL REFERENCES dim_channel (channel_key),
    store_key         INTEGER NOT NULL REFERENCES dim_store (store_key),
    province_key      INTEGER NOT NULL REFERENCES dim_province (province_key),
    order_status_key  INTEGER NOT NULL REFERENCES dim_order_status (order_status_key),
    is_sale           BOOLEAN NOT NULL,
    quantity          INTEGER NOT NULL,
    unit_price        DECIMAL(12, 2) NOT NULL,
    discount_amount   DECIMAL(12, 2) NOT NULL,
    line_total        DECIMAL(12, 2) NOT NULL,   -- quantity * unit_price - discount (sin IVA)
    sales_line_total  DECIMAL(12, 2) NOT NULL    -- line_total si is_sale, si no 0
);

INSERT INTO fact_sales_order_item
SELECT
    i.order_item_id,
    i.order_id,
    f.order_date_key,
    dp.product_key,
    f.customer_key,
    f.channel_key,
    f.store_key,
    f.province_key,
    f.order_status_key,
    f.is_sale,
    i.quantity,
    i.unit_price,
    i.discount_amount,
    i.line_total,
    CASE WHEN f.is_sale THEN i.line_total ELSE 0 END
FROM raw.sales_order_item AS i
JOIN fact_sales_order     AS f  ON f.order_id    = i.order_id
JOIN dim_product          AS dp ON dp.product_id = i.product_id;


-- ---------------------------------------------------------------------
-- fact_payment — GRANO: un pago
-- ---------------------------------------------------------------------
CREATE TABLE fact_payment (
    payment_id          BIGINT  PRIMARY KEY,
    order_id            BIGINT  NOT NULL,
    order_date_key      INTEGER NOT NULL REFERENCES dim_date (date_key),
    paid_date_key       INTEGER          REFERENCES dim_date (date_key),   -- NULL si no se pagó
    channel_key         INTEGER NOT NULL REFERENCES dim_channel (channel_key),
    payment_method_key  INTEGER NOT NULL REFERENCES dim_payment_method (payment_method_key),
    payment_status      VARCHAR NOT NULL,    -- PENDING / PAID / FAILED / REFUNDED
    amount              DECIMAL(12, 2) NOT NULL,
    minutes_to_pay      INTEGER              -- desde el pedido hasta el cobro
);

INSERT INTO fact_payment
SELECT
    p.payment_id,
    p.order_id,
    f.order_date_key,
    CAST(strftime(p.paid_at, '%Y%m%d') AS INTEGER),
    f.channel_key,
    f.payment_method_key,
    p.status,
    p.amount,
    date_diff('minute', o.order_date, p.paid_at)
FROM raw.payment         AS p
JOIN raw.sales_order     AS o ON o.order_id = p.order_id
JOIN fact_sales_order    AS f ON f.order_id = p.order_id;


-- ---------------------------------------------------------------------
-- fact_shipment — GRANO: un envío por correo
-- ---------------------------------------------------------------------
CREATE TABLE fact_shipment (
    shipment_id          BIGINT  PRIMARY KEY,
    order_id             BIGINT  NOT NULL,
    order_date_key       INTEGER NOT NULL REFERENCES dim_date (date_key),
    shipped_date_key     INTEGER          REFERENCES dim_date (date_key),   -- NULL si no salió
    delivered_date_key   INTEGER          REFERENCES dim_date (date_key),   -- NULL si no llegó
    channel_key          INTEGER NOT NULL REFERENCES dim_channel (channel_key),
    store_key            INTEGER NOT NULL REFERENCES dim_store (store_key),
    province_key         INTEGER NOT NULL REFERENCES dim_province (province_key),
    carrier              VARCHAR,
    shipment_status      VARCHAR NOT NULL,   -- READY / SHIPPED / DELIVERED / CANCELLED
    hours_to_ship        DECIMAL(10, 1),     -- pedido -> despacho
    days_to_deliver      DECIMAL(10, 1),     -- despacho -> entrega
    days_order_to_door   DECIMAL(10, 1)      -- pedido -> entrega (lo que vive el cliente)
);

INSERT INTO fact_shipment
SELECT
    s.shipment_id,
    s.order_id,
    f.order_date_key,
    CAST(strftime(s.shipped_at,   '%Y%m%d') AS INTEGER),
    CAST(strftime(s.delivered_at, '%Y%m%d') AS INTEGER),
    f.channel_key,
    f.store_key,
    f.province_key,
    s.carrier,
    s.status,
    ROUND(date_diff('minute', o.order_date, s.shipped_at)   / 60.0, 1),
    ROUND(date_diff('minute', s.shipped_at, s.delivered_at) / 1440.0, 1),
    ROUND(date_diff('minute', o.order_date, s.delivered_at) / 1440.0, 1)
FROM raw.shipment      AS s
JOIN raw.sales_order   AS o ON o.order_id = s.order_id
JOIN fact_sales_order  AS f ON f.order_id = s.order_id;


-- ---------------------------------------------------------------------
-- fact_web_session — GRANO: una visita a la web
-- ---------------------------------------------------------------------
-- Usuarios activos = clientes DISTINTOS logueados (customer_key <> -1).
-- Las visitas anónimas se guardan igual (sirven para tráfico y fuentes),
-- pero no se cuentan como usuarios: no hay forma de saber cuántas
-- personas distintas hay detrás (ver supuestos en el README).

CREATE TABLE fact_web_session (
    session_id          BIGINT  PRIMARY KEY,
    date_key            INTEGER NOT NULL REFERENCES dim_date (date_key),
    customer_key        INTEGER NOT NULL REFERENCES dim_customer (customer_key),
    traffic_source_key  INTEGER NOT NULL REFERENCES dim_traffic_source (traffic_source_key),
    device_key          INTEGER NOT NULL REFERENCES dim_device (device_key),
    is_logged_in        BOOLEAN NOT NULL,
    duration_seconds    INTEGER            -- NULL si la sesión no tiene fin registrado
);

INSERT INTO fact_web_session
SELECT
    w.session_id,
    CAST(strftime(w.started_at, '%Y%m%d') AS INTEGER),
    COALESCE(dc.customer_key, -1),
    COALESCE(ts.traffic_source_key, -1),
    COALESCE(dv.device_key, -1),
    w.customer_id IS NOT NULL,
    date_diff('second', w.started_at, w.ended_at)
FROM raw.web_session          AS w
LEFT JOIN dim_customer        AS dc ON dc.customer_id = w.customer_id
LEFT JOIN dim_traffic_source  AS ts ON ts.source_code = w.source
LEFT JOIN dim_device          AS dv ON dv.device_code = w.device;


-- ---------------------------------------------------------------------
-- fact_nps_response — GRANO: una respuesta a la encuesta
-- ---------------------------------------------------------------------
-- NPS = %promotores - %detractores. Con los flags 1/0 el cálculo en
-- Power BI es: (SUM(is_promoter) - SUM(is_detractor)) / COUNT(*) * 100.

CREATE TABLE fact_nps_response (
    nps_id         BIGINT  PRIMARY KEY,
    date_key       INTEGER NOT NULL REFERENCES dim_date (date_key),
    customer_key   INTEGER NOT NULL REFERENCES dim_customer (customer_key),
    channel_key    INTEGER NOT NULL REFERENCES dim_channel (channel_key),
    score          SMALLINT NOT NULL,
    nps_group      VARCHAR NOT NULL,   -- Promotor / Pasivo / Detractor
    is_promoter    INTEGER NOT NULL,   -- 1 si score 9-10
    is_passive     INTEGER NOT NULL,   -- 1 si score 7-8
    is_detractor   INTEGER NOT NULL,   -- 1 si score 0-6
    has_comment    BOOLEAN NOT NULL,
    comment        VARCHAR
);

INSERT INTO fact_nps_response
SELECT
    n.nps_id,
    CAST(strftime(n.responded_at, '%Y%m%d') AS INTEGER),
    COALESCE(dc.customer_key, -1),
    ch.channel_key,
    n.score,
    CASE WHEN n.score >= 9 THEN 'Promotor'
         WHEN n.score >= 7 THEN 'Pasivo'
         ELSE 'Detractor' END,
    CASE WHEN n.score >= 9 THEN 1 ELSE 0 END,
    CASE WHEN n.score BETWEEN 7 AND 8 THEN 1 ELSE 0 END,
    CASE WHEN n.score <= 6 THEN 1 ELSE 0 END,
    n.comment IS NOT NULL AND trim(n.comment) <> '',
    n.comment
FROM raw.nps_response   AS n
JOIN dim_channel        AS ch ON ch.channel_id  = n.channel_id
LEFT JOIN dim_customer  AS dc ON dc.customer_id = n.customer_id;


-- ---------------------------------------------------------------------
-- agg_sales_product_month — AGREGADO: un producto en un mes
-- ---------------------------------------------------------------------
-- Ranking mensual por producto ya calculado (solo ventas válidas).
-- Ojo: es un agregado sin canal ni provincia, así que NO responde a esos
-- filtros. Para un ranking filtrable usar fact_sales_order_item en Power BI.

CREATE TABLE agg_sales_product_month (
    month_date_key   INTEGER NOT NULL REFERENCES dim_date (date_key),   -- primer día del mes
    product_key      INTEGER NOT NULL REFERENCES dim_product (product_key),
    units            INTEGER NOT NULL,
    sales_amount     DECIMAL(14, 2) NOT NULL,   -- suma de line_total (sin IVA ni envío)
    rank_in_month    INTEGER NOT NULL,          -- 1 = el que más vendió en $ ese mes
    share_of_month   DECIMAL(6, 4) NOT NULL,    -- participación en el mes
    PRIMARY KEY (month_date_key, product_key)
);

INSERT INTO agg_sales_product_month
WITH monthly AS (
    SELECT
        CAST(strftime(d.month_start, '%Y%m%d') AS INTEGER) AS month_date_key,
        i.product_key,
        SUM(i.quantity)   AS units,
        SUM(i.line_total) AS sales_amount
    FROM fact_sales_order_item AS i
    JOIN dim_date AS d ON d.date_key = i.order_date_key
    WHERE i.is_sale
    GROUP BY ALL
)
SELECT
    month_date_key,
    product_key,
    units,
    sales_amount,
    RANK() OVER (PARTITION BY month_date_key ORDER BY sales_amount DESC),
    sales_amount / SUM(sales_amount) OVER (PARTITION BY month_date_key)
FROM monthly;
