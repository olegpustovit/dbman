# Local test DBs (Postgres 17 :55432, MariaDB 11.4 :53306, no sudo)
Start with `./up.sh` (prints the URLs); stop with `./down.sh`. Binaries come from Nix store paths.
Seed is `seed-pg.sql` / `seed-mysql.sql`, loaded only when the `shop` DB is empty (first run).
Data is in `pgdata/` and `mysqldata/`; logs and sockets in `run/`. Delete those dirs to reset.
Env: `export DBMAN_PG_URL='postgres://app:app@127.0.0.1:55432/shop?sslmode=disable' DBMAN_MYSQL_URL='mysql://app:app@127.0.0.1:53306/shop'`

Secure role (password s3cret): postgres://secure:s3cret@127.0.0.1:55432/shop, mysql://secure:s3cret@127.0.0.1:53306/shop
CA for verify-full: tls/ca.pem (add ?sslmode=verify-full&sslrootcert=<abs path>)
