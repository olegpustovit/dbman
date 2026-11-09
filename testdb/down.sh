#!/bin/sh
# Stop both test servers (data kept in pgdata/ and mysqldata/).
set -u
cd "$(dirname "$0")"
export PATH=/nix/var/nix/profiles/default/bin:$PATH
PG=$(nix eval --raw nixpkgs#postgresql_17.outPath)/bin
MA=$(nix eval --raw nixpkgs#mariadb.outPath)/bin
"$PG/pg_ctl" -D pgdata stop -m fast -w >/dev/null 2>&1
"$MA/mariadb-admin" --no-defaults --skip-ssl -S "$PWD/run/mysql.sock" -uroot shutdown >/dev/null 2>&1
echo "stopped"
