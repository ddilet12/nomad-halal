#!/usr/bin/env bash
# Прогон миграций и тестов на локальном Postgres (без Supabase).
# Использование: PGHOST=/tmp PGPORT=54329 PGUSER=postgres ./supabase/tests/run_local.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DB=${TEST_DB:-nh_test}
psql -v ON_ERROR_STOP=1 -q -d postgres -c "drop database if exists $DB" -c "create database $DB"
for f in tests/00_local_supabase_stub.sql migrations/*.sql tests/01_test_helpers.sql tests/02_fixtures.sql tests/1*.sql; do
  echo "== $f"
  psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$f"
done
