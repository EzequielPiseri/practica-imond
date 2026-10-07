-- =====================================================================
-- 01_dimensiones.sql — Tablas de DIMENSIONES del modelo estrella
-- =====================================================================
-- Convenciones del modelo:
--   * <x>_key  = clave SUBROGADA (propia del DW). Es la que usan los hechos.
--   * <x>_id   = clave NATURAL (la que viene de raw/).
--   * Clave -1 = miembro "Desconocido / No aplica" (cliente anónimo,
--                pedido online sin tienda, etc.). Así los hechos nunca
--                tienen FK nulas y Power BI no pierde filas al relacionar.
--   * Fechas   = date_key entero AAAAMMDD (ej. 20240131).
-- =====================================================================


-- ---------------------------------------------------------------------
-- dim_product (ejemplo resuelto de la consigna, sin cambios)
-- ---------------------------------------------------------------------
-- La categoría está en otra tabla con jerarquía (Bottles -> Classic / Sport).
-- En la dimensión la "aplanamos": una fila por producto con categoría y familia.

CREATE TABLE dim_product (
    product_key INTEGER PRIMARY KEY,
    product_id  INTEGER NOT NULL,
    sku         VARCHAR NOT NULL,
    name        VARCHAR NOT NULL,
    category    VARCHAR,             -- Classic / Sport
    family      VARCHAR,             -- Bottles
    list_price  DECIMAL(12, 2)
);

INSERT INTO dim_product
SELECT
    ROW_NUMBER() OVER (ORDER BY p.product_id) AS product_key,
    p.product_id,
    p.sku,
    p.name,
    c.name AS category,
    f.name AS family,
    p.list_price
FROM raw.product AS p
LEFT JOIN raw.product_category AS c ON c.category_id = p.category_id   -- categoría
LEFT JOIN raw.product_category AS f ON f.category_id = c.parent_id;    -- familia (categoría padre)


-- ---------------------------------------------------------------------
-- dim_date — calendario (dimensión de rol: fecha de pedido, pago,
-- envío, entrega, sesión y respuesta NPS apuntan todas acá)
-- ---------------------------------------------------------------------
-- Rango: 01/01/2024 al 31/10/2025. Cubre todos los eventos de raw/
-- (la foto es del 30/09/2025) con margen.

CREATE TABLE dim_date (
    date_key       INTEGER PRIMARY KEY,   -- AAAAMMDD
    date           DATE    NOT NULL,
    year           INTEGER NOT NULL,
    quarter        INTEGER NOT NULL,
    month          INTEGER NOT NULL,
    month_name     VARCHAR NOT NULL,      -- Enero, Febrero...
    year_month     VARCHAR NOT NULL,      -- 2024-01 (ordena bien como texto)
    month_start    DATE    NOT NULL,      -- primer día del mes (eje de series mensuales)
    day            INTEGER NOT NULL,
    day_of_week    INTEGER NOT NULL,      -- 1 = lunes ... 7 = domingo (ISO)
    day_name       VARCHAR NOT NULL,      -- Lunes, Martes...
    is_weekend     BOOLEAN NOT NULL
);

INSERT INTO dim_date
SELECT
    CAST(strftime(d, '%Y%m%d') AS INTEGER)                    AS date_key,
    d                                                         AS date,
    year(d), quarter(d), month(d),
    ['Enero','Febrero','Marzo','Abril','Mayo','Junio','Julio',
     'Agosto','Septiembre','Octubre','Noviembre','Diciembre'][month(d)],
    strftime(d, '%Y-%m'),
    CAST(date_trunc('month', d) AS DATE),
    day(d),
    isodow(d),
    ['Lunes','Martes','Miércoles','Jueves','Viernes','Sábado','Domingo'][isodow(d)],
    isodow(d) IN (6, 7)
FROM (
    SELECT CAST(range AS DATE) AS d
    FROM range(DATE '2024-01-01', DATE '2025-11-01', INTERVAL 1 DAY)
);


-- ---------------------------------------------------------------------
-- dim_channel — canal de venta (ONLINE / OFFLINE)
-- ---------------------------------------------------------------------
CREATE TABLE dim_channel (
    channel_key INTEGER PRIMARY KEY,
    channel_id  INTEGER NOT NULL,
    code        VARCHAR NOT NULL,
    name        VARCHAR NOT NULL
);

INSERT INTO dim_channel
SELECT ROW_NUMBER() OVER (ORDER BY channel_id), channel_id, code, name
FROM raw.channel;


-- ---------------------------------------------------------------------
-- dim_province — geografía para "Ventas por provincia"
-- ---------------------------------------------------------------------
-- iso_code (ISO 3166-2) es lo que usan los mapas para ubicar la provincia
-- sin ambigüedad ("Santa Fe" sola puede caer en Santa Fe, Nuevo México).

CREATE TABLE dim_province (
    province_key  INTEGER PRIMARY KEY,
    province_id   INTEGER NOT NULL,
    name          VARCHAR NOT NULL,
    code          VARCHAR,
    iso_code      VARCHAR,               -- AR-B, AR-X, AR-S, AR-M
    country_name  VARCHAR NOT NULL
);

INSERT INTO dim_province
SELECT
    ROW_NUMBER() OVER (ORDER BY province_id),
    province_id, name, code,
    CASE code WHEN 'BA'  THEN 'AR-B'
              WHEN 'CBA' THEN 'AR-X'
              WHEN 'SF'  THEN 'AR-S'
              WHEN 'MZA' THEN 'AR-M' END,
    'Argentina'
FROM raw.province;

INSERT INTO dim_province VALUES (-1, -1, 'Desconocida', NULL, NULL, 'Argentina');


-- ---------------------------------------------------------------------
-- dim_store — tiendas físicas (+ fila -1 "Tienda online" para el canal web)
-- ---------------------------------------------------------------------
CREATE TABLE dim_store (
    store_key     INTEGER PRIMARY KEY,
    store_id      INTEGER,               -- NULL en la fila -1
    name          VARCHAR NOT NULL,
    city          VARCHAR,
    province_name VARCHAR,
    is_physical   BOOLEAN NOT NULL
);

INSERT INTO dim_store
SELECT
    ROW_NUMBER() OVER (ORDER BY s.store_id),
    s.store_id, s.name, a.city, pr.name, TRUE
FROM raw.store AS s
JOIN raw.address  AS a  ON a.address_id  = s.address_id
JOIN raw.province AS pr ON pr.province_id = a.province_id;

INSERT INTO dim_store VALUES (-1, NULL, 'Tienda online (sin tienda física)', NULL, NULL, FALSE);


-- ---------------------------------------------------------------------
-- dim_customer — clientes (+ fila -1 "Anónimo")
-- ---------------------------------------------------------------------
-- No se guardan email ni teléfono: son datos personales que el tablero
-- no necesita (minimización de datos). La provincia es la de la
-- dirección de envío más usada por el cliente, sin contar tiendas
-- (si empata, la del pedido más reciente).

CREATE TABLE dim_customer (
    customer_key   INTEGER PRIMARY KEY,
    customer_id    INTEGER,              -- NULL en la fila -1
    full_name      VARCHAR NOT NULL,
    status         VARCHAR NOT NULL,     -- Activo / Inactivo / Desconocido
    created_date   DATE,
    cohort_month   VARCHAR,              -- mes de alta, para análisis de cohortes
    province_name  VARCHAR
);

INSERT INTO dim_customer
WITH home_address AS (
    -- Dirección "de casa" del cliente: la más usada como envío, sin contar tiendas
    SELECT customer_id, province_id
    FROM (
        SELECT o.customer_id, a.province_id,
               ROW_NUMBER() OVER (PARTITION BY o.customer_id
                                  ORDER BY COUNT(*) DESC, MAX(o.order_date) DESC) AS rn
        FROM raw.sales_order AS o
        JOIN raw.address AS a ON a.address_id = o.shipping_address_id
        WHERE o.shipping_address_id NOT IN (SELECT address_id FROM raw.store)
        GROUP BY o.customer_id, a.province_id
    )
    WHERE rn = 1
)
SELECT
    ROW_NUMBER() OVER (ORDER BY c.customer_id),
    c.customer_id,
    c.first_name || ' ' || c.last_name,
    CASE c.status WHEN 'A' THEN 'Activo' WHEN 'I' THEN 'Inactivo' END,
    CAST(c.created_at AS DATE),
    strftime(c.created_at, '%Y-%m'),
    pr.name
FROM raw.customer AS c
LEFT JOIN home_address AS h  ON h.customer_id  = c.customer_id
LEFT JOIN raw.province AS pr ON pr.province_id = h.province_id;

INSERT INTO dim_customer VALUES (-1, NULL, 'Anónimo', 'Desconocido', NULL, NULL, NULL);


-- ---------------------------------------------------------------------
-- dim_order_status — estado del pedido y si cuenta como venta
-- ---------------------------------------------------------------------
-- La regla de negocio "solo PAID y FULFILLED son venta" queda en UN lugar
-- (is_sale), en vez de repetir el filtro en cada consulta y en cada medida.

CREATE TABLE dim_order_status (
    order_status_key INTEGER PRIMARY KEY,
    status_code      VARCHAR NOT NULL,
    description      VARCHAR NOT NULL,
    is_sale          BOOLEAN NOT NULL
);

INSERT INTO dim_order_status VALUES
    (1, 'CREATED',   'Creado, sin pagar',          FALSE),
    (2, 'PAID',      'Pagado, sin entregar',       TRUE),
    (3, 'FULFILLED', 'Entregado',                  TRUE),
    (4, 'CANCELLED', 'Cancelado',                  FALSE),
    (5, 'REFUNDED',  'Entregado y reembolsado',    FALSE);


-- ---------------------------------------------------------------------
-- dim_payment_method — medio de pago
-- ---------------------------------------------------------------------
CREATE TABLE dim_payment_method (
    payment_method_key INTEGER PRIMARY KEY,
    method_code        VARCHAR NOT NULL,
    description        VARCHAR NOT NULL
);

INSERT INTO dim_payment_method VALUES
    (1, 'CASH',     'Efectivo'),
    (2, 'CARD',     'Tarjeta'),
    (3, 'TRANSFER', 'Transferencia'),
    (4, 'GATEWAY',  'Pasarela de pago (Mercado Pago)');


-- ---------------------------------------------------------------------
-- dim_traffic_source — origen de la visita web
-- ---------------------------------------------------------------------
CREATE TABLE dim_traffic_source (
    traffic_source_key INTEGER PRIMARY KEY,
    source_code        VARCHAR NOT NULL,
    description        VARCHAR NOT NULL,
    is_paid            BOOLEAN NOT NULL       -- tráfico pago vs. orgánico/propio
);

INSERT INTO dim_traffic_source VALUES
    (1, 'ads',      'Publicidad en redes',            TRUE),
    -- direct y referral incluyen el tráfico del newsletter (README del generador)
    (2, 'direct',   'Directo (incl. newsletter)',     FALSE),
    (3, 'referral', 'Referidos (incl. newsletter)',   FALSE),
    (4, 'organic',  'Buscadores',                     FALSE),
    (-1, 'unknown', 'Desconocido',                    FALSE);


-- ---------------------------------------------------------------------
-- dim_device — dispositivo de la visita web
-- ---------------------------------------------------------------------
CREATE TABLE dim_device (
    device_key  INTEGER PRIMARY KEY,
    device_code VARCHAR NOT NULL,
    description VARCHAR NOT NULL
);

INSERT INTO dim_device VALUES
    (1, 'desktop', 'Computadora'),
    (2, 'mobile',  'Celular'),
    (3, 'tablet',  'Tablet'),
    (-1, 'unknown', 'Desconocido');
