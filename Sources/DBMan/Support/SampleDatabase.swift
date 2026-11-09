import DBCore
import Foundation
import SQLite3

/// Canonical demo dataset (290,198 rows), built once with recursive CTEs via the raw sqlite3 API.
enum SampleDatabase {
    static func ensure() throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("DBMan")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sample.sqlite")
        if fm.fileExists(atPath: url.path) { return url }
        // Build beside the target and rename, so a crash never leaves a half-filled sample.sqlite.
        let tmp = dir.appendingPathComponent("sample.sqlite.tmp")
        try? fm.removeItem(at: tmp)
        var db: OpaquePointer?
        guard sqlite3_open(tmp.path, &db) == SQLITE_OK else { throw DBError.connection("Cannot create sample database") }
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, script, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            try? fm.removeItem(at: tmp)
            throw DBError.query("Sample database: \(m)")
        }
        sqlite3_close(db); db = nil
        try fm.moveItem(at: tmp, to: url)
        return url
    }

    // Day offsets use 311*(1.6t-0.6t²): Jan 2 → Nov 9 2026 with order density growing ~4x.
    private static let script = """
    PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;
    BEGIN;
    CREATE TABLE customers(id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL, country TEXT, plan TEXT, created_at TEXT NOT NULL);
    CREATE TABLE products(id INTEGER PRIMARY KEY, sku TEXT NOT NULL, name TEXT NOT NULL, category TEXT, price REAL NOT NULL, stock INTEGER NOT NULL);
    CREATE TABLE orders(id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES customers(id), status TEXT NOT NULL, total REAL, currency TEXT NOT NULL DEFAULT 'USD', created_at TEXT NOT NULL, shipped_at TEXT);
    CREATE TABLE order_items(id INTEGER PRIMARY KEY, order_id INTEGER NOT NULL REFERENCES orders(id), product_id INTEGER NOT NULL REFERENCES products(id), quantity INTEGER NOT NULL, unit_price REAL NOT NULL);
    CREATE TABLE invoices(id INTEGER PRIMARY KEY, order_id INTEGER NOT NULL REFERENCES orders(id), amount REAL, status TEXT NOT NULL, issued_at TEXT NOT NULL, paid_at TEXT);
    CREATE TABLE events(id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id), kind TEXT NOT NULL, payload TEXT, occurred_at TEXT NOT NULL);

    INSERT INTO customers
    WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<2400)
    SELECT i,
      (SELECT value FROM json_each('["Ana","Ben","Chloe","Dev","Elena","Farid","Grace","Hugo","Iris","Jon","Kira","Leo"]') WHERE key=i%12)||' '||
      (SELECT value FROM json_each('["Park","Silva","Nguyen","Okafor","Muller","Rossi","Haas","Sato","Cohen","Ivanov","Costa"]') WHERE key=i%11),
      'user'||i||'@example.com',
      (SELECT value FROM json_each('["US","DE","FR","JP","BR","GB","IN","CA"]') WHERE key=(i*7)%8),
      (SELECT value FROM json_each('["free","pro","team","enterprise"]') WHERE key=(i*5)%4),
      datetime(1767312000 - (i*86400*3)%31536000, 'unixepoch')
    FROM n;

    INSERT INTO products
    WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<240)
    SELECT i, 'SKU-'||printf('%04d',i), 'Product '||i,
      (SELECT value FROM json_each('["Hardware","Software","Books","Apparel","Office","Audio"]') WHERE key=i%6),
      round(5 + ((i*977)%19500)/100.0, 2), (i*53)%500
    FROM n;

    INSERT INTO orders(id, customer_id, status, currency, created_at, shipped_at)
    WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<48000),
    o AS (SELECT i, (i*37)%100 AS b,
      1767312000 + CAST(311*86400*((i/48000.0)*(1.6-0.6*(i/48000.0))) AS INTEGER) + (i*7919)%86400 AS ts FROM n)
    SELECT 10431+i, 1+(i*7919)%2400,
      CASE WHEN b<39 THEN 'paid' WHEN b<67 THEN 'delivered' WHEN b<92 THEN 'shipped' WHEN b<97 THEN 'pending' ELSE 'refunded' END,
      'USD', datetime(MIN(ts, 1767312000+311*86400+86399), 'unixepoch'),
      CASE WHEN b>=39 AND b<92 THEN datetime(MIN(ts, 1767312000+311*86400+86399) + 86400*(1+i%3), 'unixepoch') END
    FROM o;

    INSERT INTO order_items(order_id, product_id, quantity, unit_price)
    WITH RECURSIVE kk(k) AS (SELECT 1 UNION ALL SELECT k+1 FROM kk WHERE k<6)
    SELECT o.id, 1+(o.id*31+kk.k*17)%240, 1+(o.id+kk.k)%4, p.price
    FROM orders o JOIN kk ON kk.k <= 1+((o.id-10431)*13)%6
    JOIN products p ON p.id = 1+(o.id*31+kk.k*17)%240;

    CREATE INDEX idx_items_order ON order_items(order_id);
    UPDATE orders SET total = (SELECT round(SUM(quantity*unit_price),2) FROM order_items WHERE order_id=orders.id);

    INSERT INTO invoices(order_id, amount, status, issued_at, paid_at)
    WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<9812)
    SELECT o.id, o.total,
      CASE WHEN i%10<7 THEN 'paid' WHEN i%10<9 THEN 'open' ELSE 'overdue' END,
      o.created_at,
      CASE WHEN i%10<7 THEN datetime(o.created_at, '+'||(1+i%14)||' days') END
    FROM n JOIN orders o ON o.id = 10431 + i*4;

    INSERT INTO events(customer_id, kind, payload, occurred_at)
    WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<61532)
    SELECT 1+(i*104729)%2400,
      (SELECT value FROM json_each('["page_view","search","add_to_cart","checkout","login"]') WHERE key=i%5),
      '{"session":"s'||(i%9000)||'"}',
      datetime(1767312000 + (i*311*86400)/61532, 'unixepoch')
    FROM n;

    CREATE INDEX idx_orders_customer ON orders(customer_id);
    CREATE INDEX idx_orders_created ON orders(created_at);
    CREATE INDEX idx_invoices_order ON invoices(order_id);
    CREATE INDEX idx_events_customer ON events(customer_id);
    CREATE VIEW revenue_by_month AS
      SELECT strftime('%Y-%m', created_at) AS month, COUNT(*) AS orders, round(SUM(total),2) AS revenue
      FROM orders WHERE status IN ('paid','delivered','shipped') GROUP BY 1;
    COMMIT;
    ANALYZE;
    """
}
