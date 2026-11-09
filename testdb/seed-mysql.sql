-- Canonical sample dataset (MySQL 8 / MariaDB). Load with: mariadb shop < seed-mysql.sql
SET FOREIGN_KEY_CHECKS = 0;
DROP VIEW IF EXISTS revenue_by_month;
DROP TABLE IF EXISTS events, invoices, order_items, orders, products, customers;
SET FOREIGN_KEY_CHECKS = 1;

-- helper: numbers 1..65536 (two 256-row recursions keep both MySQL and MariaDB recursion limits happy)
DROP TABLE IF EXISTS seq_tmp;
CREATE TABLE seq_tmp (n INT PRIMARY KEY);
INSERT INTO seq_tmp (n)
WITH RECURSIVE d(n) AS (SELECT 0 UNION ALL SELECT n + 1 FROM d WHERE n < 255)
SELECT a.n * 256 + b.n + 1 FROM d a CROSS JOIN d b;

CREATE TABLE customers (
  id         INT PRIMARY KEY,
  name       VARCHAR(100) NOT NULL,
  email      VARCHAR(190) NOT NULL UNIQUE,
  plan       VARCHAR(20) NOT NULL,
  city       VARCHAR(60),
  created_at DATETIME NOT NULL
);
CREATE TABLE products (
  id    INT PRIMARY KEY,
  sku   VARCHAR(32) NOT NULL UNIQUE,
  name  VARCHAR(100) NOT NULL,
  price DECIMAL(10,2) NOT NULL CHECK (price >= 0),
  stock INT NOT NULL CHECK (stock >= 0)
);
CREATE TABLE orders (
  id          INT PRIMARY KEY,
  customer_id INT NOT NULL,
  status      VARCHAR(20) NOT NULL CHECK (status IN ('paid','delivered','shipped','pending','refunded')),
  total       DECIMAL(12,2) NOT NULL DEFAULT 0,
  items       INT NOT NULL CHECK (items > 0),
  created_at  DATETIME NOT NULL,
  shipped_at  DATETIME NULL,
  CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE CASCADE,
  INDEX idx_orders_customer (customer_id),
  INDEX idx_orders_created (created_at)
);
CREATE TABLE order_items (
  id         INT AUTO_INCREMENT PRIMARY KEY,
  order_id   INT NOT NULL,
  product_id INT NOT NULL,
  quantity   INT NOT NULL CHECK (quantity > 0),
  unit_price DECIMAL(10,2) NOT NULL,
  CONSTRAINT fk_items_order FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE,
  CONSTRAINT fk_items_product FOREIGN KEY (product_id) REFERENCES products(id)
);
CREATE TABLE invoices (
  id        INT AUTO_INCREMENT PRIMARY KEY,
  order_id  INT NOT NULL,
  amount    DECIMAL(12,2) NOT NULL,
  issued_at DATETIME NOT NULL,
  CONSTRAINT fk_invoices_order FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE RESTRICT
);
CREATE TABLE events (
  id          BIGINT AUTO_INCREMENT PRIMARY KEY,
  kind        VARCHAR(32) NOT NULL,
  customer_id INT NULL,
  latency_ms  INT,
  payload     JSON,
  `at`        DATETIME NOT NULL,
  CONSTRAINT fk_events_customer FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE SET NULL
);

INSERT INTO customers (id, name, email, plan, city, created_at)
SELECT n, CONCAT('Customer ', n), CONCAT('user', n, '@example.test'),
       ELT(1 + n % 3, 'free','pro','team'),
       ELT(1 + n % 8, 'Berlin','Paris','Madrid','Lisbon','Warsaw','Oslo','Rome','Vienna'),
       '2023-01-01 00:00:00' + INTERVAL (n % 700) DAY
FROM seq_tmp WHERE n <= 2400;

INSERT INTO products (id, sku, name, price, stock)
SELECT n, CONCAT('SKU-', LPAD(n, 4, '0')), CONCAT('Product ', n), 4.99 + (n * 37 % 400), n * 53 % 500
FROM seq_tmp WHERE n <= 240;

-- orders: ids 10432..58431, items = 1..6 lines each (avg 3.5)
INSERT INTO orders (id, customer_id, status, items, created_at, shipped_at)
SELECT o.id, o.customer_id, o.status, o.items, o.ts,
       IF(o.status IN ('shipped','delivered'), o.ts + INTERVAL 2 DAY, NULL)
FROM (
  SELECT 10431 + n AS id, 1 + (n * 31) % 2400 AS customer_id,
         ELT(1 + n % 5, 'paid','delivered','shipped','pending','refunded') AS status,
         1 + n % 6 AS items,
         '2024-01-01 00:00:00' + INTERVAL (n % 900) DAY + INTERVAL (n % 1440) MINUTE AS ts
  FROM seq_tmp WHERE n <= 48000) o;

INSERT INTO order_items (order_id, product_id, quantity, unit_price)
SELECT x.order_id, p.id, x.qty, p.price
FROM (SELECT o.id AS order_id, 1 + (o.id * 7 + k.n * 13) % 240 AS product_id, 1 + (o.id + k.n) % 3 AS qty
      FROM orders o JOIN (SELECT n FROM seq_tmp WHERE n <= 6) k ON k.n <= o.items) x
JOIN products p ON p.id = x.product_id;

UPDATE orders o JOIN (SELECT order_id, SUM(quantity * unit_price) AS t FROM order_items GROUP BY order_id) s
  ON s.order_id = o.id
SET o.total = s.t;

-- invoices for the first 9812 orders
INSERT INTO invoices (order_id, amount, issued_at)
SELECT id, total, created_at + INTERVAL 1 DAY FROM orders WHERE id < 10432 + 9812;

INSERT INTO events (kind, customer_id, latency_ms, payload, `at`)
SELECT ELT(1 + n % 5, 'login','view','checkout','error','logout'),
       IF(n % 11 = 0, NULL, 1 + (n * 17) % 2400),
       5 + (n * 97) % 900,
       JSON_OBJECT('n', n, 'agent', CONCAT('agent-', n % 4)),
       '2024-01-01 00:00:00' + INTERVAL (n % 900) DAY + INTERVAL (n % 1440) MINUTE
FROM seq_tmp WHERE n <= 61532;

CREATE VIEW revenue_by_month AS
SELECT DATE_FORMAT(created_at, '%Y-%m') AS month,
       COUNT(*) AS order_count, SUM(total) AS revenue
FROM orders WHERE status <> 'refunded'
GROUP BY DATE_FORMAT(created_at, '%Y-%m');

DROP TABLE seq_tmp;
