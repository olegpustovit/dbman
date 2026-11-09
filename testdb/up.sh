#!/bin/sh
# Start Postgres 17 (127.0.0.1:55432) and MariaDB 11.4 (127.0.0.1:53306) from Nix store paths. No sudo.
set -eu
cd "$(dirname "$0")"
export PATH=/nix/var/nix/profiles/default/bin:$PATH
nix build --no-link nixpkgs#postgresql_17 nixpkgs#mariadb
PG=$(nix eval --raw nixpkgs#postgresql_17.outPath)/bin
MAB=$(nix eval --raw nixpkgs#mariadb.outPath); MA=$MAB/bin
D=$PWD; R=$D/run; S=$R/mysql.sock
mkdir -p "$R"
# Local CA + server cert for 127.0.0.1 and localhost (SAN IP + DNS), made once; both servers use cert.pem/key.pem. Regenerating restarts servers.
if [ ! -f tls/ca.pem ] || ! openssl x509 -in tls/cert.pem -noout -text 2>/dev/null | grep -q 'DNS:localhost'; then
  ./down.sh >/dev/null; mkdir -p tls; rm -f tls/cert.pem tls/key.pem
  openssl req -x509 -newkey rsa:2048 -nodes -keyout tls/ca-key.pem -out tls/ca.pem -days 825 -subj "/CN=DBMan Test CA" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -keyout tls/key.pem -out tls/server.csr -subj /CN=127.0.0.1 2>/dev/null
  printf 'subjectAltName=IP:127.0.0.1,DNS:localhost\nbasicConstraints=CA:FALSE\n' >tls/ext.cnf
  openssl x509 -req -in tls/server.csr -CA tls/ca.pem -CAkey tls/ca-key.pem -CAcreateserial -out tls/cert.pem -days 825 -extfile tls/ext.cnf 2>/dev/null
  rm -f tls/server.csr tls/ext.cnf; chmod 600 tls/key.pem tls/ca-key.pem
fi

# PostgreSQL (trust auth, local only; ssl optional, plain still allowed)
[ -f pgdata/PG_VERSION ] || "$PG/initdb" -D pgdata -U postgres -A trust >/dev/null
"$PG/pg_ctl" -D pgdata status >/dev/null 2>&1 ||
  "$PG/pg_ctl" -D pgdata -l "$R/pg.log" -w -o "-p 55432 -h 127.0.0.1 -k $R -c ssl=on -c ssl_cert_file=$D/tls/cert.pem -c ssl_key_file=$D/tls/key.pem" start >/dev/null
PSQL="$PG/psql -h 127.0.0.1 -p 55432 -U postgres -v ON_ERROR_STOP=1 -q"
$PSQL -d postgres -tAc "select 1 from pg_roles where rolname='app'" | grep -q 1 ||
  $PSQL -d postgres -c "create role app login password 'app'"
# 'secure' must use a password: scram line goes above the trust lines
grep -q '^host all secure ' pgdata/pg_hba.conf || {
  { echo 'host all secure 127.0.0.1/32 scram-sha-256'; cat pgdata/pg_hba.conf; } >run/hba.tmp && cp run/hba.tmp pgdata/pg_hba.conf
  "$PG/pg_ctl" -D pgdata reload >/dev/null; }
$PSQL -d postgres -tAc "select 1 from pg_roles where rolname='secure'" | grep -q 1 ||
  $PSQL -d postgres -c "set password_encryption='scram-sha-256'" -c "create role secure login password 's3cret'"
$PSQL -d postgres -tAc "select 1 from pg_database where datname='shop'" | grep -q 1 ||
  $PSQL -d postgres -c "create database shop owner app"
$PSQL -d shop -tAc "select to_regclass('orders')" | grep -q orders ||
  $PG/psql -h 127.0.0.1 -p 55432 -U app -d shop -v ON_ERROR_STOP=1 -1 -q -f seed-pg.sql

# MariaDB (root over unix socket, app over TCP)
[ -d mysqldata/mysql ] || "$MA/mariadb-install-db" --no-defaults --basedir="$MAB" --datadir="$D/mysqldata" \
  --auth-root-authentication-method=normal >"$R/install.log" 2>&1
"$MA/mariadb-admin" --no-defaults -S "$S" -uroot ping >/dev/null 2>&1 || {
  nohup "$MA/mariadbd" --no-defaults --basedir="$MAB" --datadir="$D/mysqldata" --socket="$S" \
    --port=53306 --bind-address=127.0.0.1 --pid-file="$R/mysql.pid" --log-error="$R/mysql.log" \
    --ssl-cert="$D/tls/cert.pem" --ssl-key="$D/tls/key.pem" \
    </dev/null >/dev/null 2>&1 &
  for i in $(seq 60); do "$MA/mariadb-admin" --no-defaults -S "$S" -uroot ping >/dev/null 2>&1 && break; sleep 1; done
}
ROOT="$MA/mariadb --no-defaults --skip-ssl -S $S -uroot"
# app@localhost too: the anonymous ''@localhost account would otherwise shadow app@'%' for TCP
$ROOT -e "CREATE DATABASE IF NOT EXISTS shop; DROP USER IF EXISTS ''@'localhost';
  CREATE USER IF NOT EXISTS 'app'@'%' IDENTIFIED BY 'app'; CREATE USER IF NOT EXISTS 'app'@'localhost' IDENTIFIED BY 'app';
  CREATE USER IF NOT EXISTS 'secure'@'%' IDENTIFIED BY 's3cret'; CREATE USER IF NOT EXISTS 'secure'@'localhost' IDENTIFIED BY 's3cret';
  GRANT SELECT ON shop.* TO 'secure'@'%'; GRANT SELECT ON shop.* TO 'secure'@'localhost';
  GRANT ALL ON shop.* TO 'app'@'%'; GRANT ALL ON shop.* TO 'app'@'localhost'; FLUSH PRIVILEGES;"
MY="$MA/mariadb --no-defaults --ssl-ca=$D/tls/ca.pem -h127.0.0.1 -P53306 -uapp -papp shop"
[ -n "$($MY -N -e "show tables like 'orders'")" ] || $MY < seed-mysql.sql

echo "postgres://app:app@127.0.0.1:55432/shop?sslmode=disable"
echo "mysql://app:app@127.0.0.1:53306/shop"
