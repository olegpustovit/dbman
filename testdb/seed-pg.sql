-- Canonical sample dataset (PostgreSQL). Run with: psql -1 -v ON_ERROR_STOP=1 -f seed-pg.sql
DROP VIEW IF EXISTS revenue_by_month;
DROP TABLE IF EXISTS events, invoices, order_items, orders, products, customers;

CREATE TABLE customers (
  id         int PRIMARY KEY,
  name       text NOT NULL,
  email      text NOT NULL UNIQUE,
  plan       text NOT NULL,
  city       text,
  created_at timestamptz NOT NULL
);
CREATE TABLE products (
  id    int PRIMARY KEY,
  sku   text NOT NULL UNIQUE,
  name  text NOT NULL,
  price numeric(10,2) NOT NULL CHECK (price >= 0),
  stock int NOT NULL CHECK (stock >= 0)
);
CREATE TABLE orders (
  id          int PRIMARY KEY,
  customer_id int NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  status      text NOT NULL CHECK (status IN ('paid','delivered','shipped','pending','refunded')),
  total       numeric(12,2) NOT NULL DEFAULT 0,
  items       int NOT NULL CHECK (items > 0),
  created_at  timestamptz NOT NULL,
  shipped_at  timestamptz
);
CREATE INDEX idx_orders_customer ON orders(customer_id);
CREATE INDEX idx_orders_created  ON orders(created_at);
CREATE TABLE order_items (
  id         int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_id   int NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  product_id int NOT NULL REFERENCES products(id),
  quantity   int NOT NULL CHECK (quantity > 0),
  unit_price numeric(10,2) NOT NULL
);
CREATE TABLE invoices (
  id        int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_id  int NOT NULL REFERENCES orders(id) ON DELETE RESTRICT,
  amount    numeric(12,2) NOT NULL,
  issued_at timestamptz NOT NULL
);
CREATE TABLE events (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind        text NOT NULL,
  customer_id int REFERENCES customers(id) ON DELETE SET NULL,
  latency_ms  int,
  payload     json,
  "at"        timestamptz NOT NULL
);

INSERT INTO customers (id, name, email, plan, city, created_at)
SELECT g, 'Customer ' || g, 'user' || g || '@example.test',
       (ARRAY['free','pro','team'])[1 + g % 3],
       (ARRAY['Berlin','Paris','Madrid','Lisbon','Warsaw','Oslo','Rome','Vienna'])[1 + g % 8],
       timestamptz '2023-01-01 00:00+00' + (g % 700) * interval '1 day'
FROM generate_series(1, 2400) g;

INSERT INTO products (id, sku, name, price, stock)
SELECT g, 'SKU-' || lpad(g::text, 4, '0'), 'Product ' || g, 4.99 + (g * 37 % 400), g * 53 % 500
FROM generate_series(1, 240) g;

-- orders: ids 10432..58431, items = 1..6 lines each (avg 3.5)
INSERT INTO orders (id, customer_id, status, items, created_at, shipped_at)
SELECT o.id, o.customer_id, o.status, o.items, o.ts,
       CASE WHEN o.status IN ('shipped','delivered') THEN o.ts + interval '2 days' END
FROM (
  SELECT 10431 + g AS id, 1 + (g * 31) % 2400 AS customer_id,
         (ARRAY['paid','delivered','shipped','pending','refunded'])[1 + g % 5] AS status,
         1 + g % 6 AS items,
         timestamptz '2024-01-01 00:00+00' + (g % 900) * interval '1 day' + (g % 1440) * interval '1 minute' AS ts
  FROM generate_series(1, 48000) g) o;

INSERT INTO order_items (order_id, product_id, quantity, unit_price)
SELECT x.order_id, p.id, x.qty, p.price
FROM (SELECT o.id AS order_id, 1 + (o.id * 7 + k * 13) % 240 AS product_id, 1 + (o.id + k) % 3 AS qty
      FROM orders o CROSS JOIN generate_series(1, 6) k
      WHERE k <= o.items) x
JOIN products p ON p.id = x.product_id;

UPDATE orders o SET total = s.t
FROM (SELECT order_id, sum(quantity * unit_price) AS t FROM order_items GROUP BY order_id) s
WHERE s.order_id = o.id;

-- invoices for the first 9812 orders
INSERT INTO invoices (order_id, amount, issued_at)
SELECT id, total, created_at + interval '1 day' FROM orders WHERE id < 10432 + 9812;

INSERT INTO events (kind, customer_id, latency_ms, payload, "at")
SELECT (ARRAY['login','view','checkout','error','logout'])[1 + g % 5],
       CASE WHEN g % 11 = 0 THEN NULL ELSE 1 + (g * 17) % 2400 END,
       5 + (g * 97) % 900,
       json_build_object('n', g, 'agent', 'agent-' || g % 4),
       timestamptz '2024-01-01 00:00+00' + (g % 900) * interval '1 day' + (g % 1440) * interval '1 minute'
FROM generate_series(1, 61532) g;

CREATE VIEW revenue_by_month AS
SELECT to_char(date_trunc('month', created_at AT TIME ZONE 'UTC'), 'YYYY-MM') AS month,
       count(*) AS order_count, sum(total) AS revenue
FROM orders WHERE status <> 'refunded'
GROUP BY 1;

