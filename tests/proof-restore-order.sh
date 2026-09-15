#!/usr/bin/env bash
# Proof for the restore ORDER: a product dump needs roles that are not in it.
#
#   bash tests/proof-restore-order.sh        (needs docker; ~40s, 3 scratch clusters)
#
# This reproduces the finding the roles file exists for, on this machine,
# rather than citing it. Three throwaway clusters:
#   A  stands in for a live instance: the roles, a table, a GRANT to web_anon
#   B  a FRESH cluster, product dump replayed with NO roles   -> must FAIL
#   C  a FRESH cluster, roles loaded FIRST, then the dump     -> must PASS
# If B ever passes, the roles file is not load-bearing and this proof is what
# says so. If C fails, `install.sh --restore` is wrong.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)
A="" B="" C=""
cleanup() { for c in $A $B $C; do docker rm -f "$c" >/dev/null 2>&1; done; rm -rf "$T"; }
trap cleanup EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ✓ %s\n' "$*"; }
bad() { fail=$((fail+1)); printf '  ✗ %s\n' "$*"; }

start() {   # echo a container id that answers two consecutive queries
  local cid; cid=$(docker run -d --rm -e POSTGRES_PASSWORD=p -e POSTGRES_USER=drill postgres:16-alpine 2>/dev/null)
  [ -n "$cid" ] || return 1
  local ready=0 i
  for i in $(seq 1 60); do
    if docker exec "$cid" psql -U drill -d postgres -tAc 'select 1' >/dev/null 2>&1; then ready=$((ready+1)); else ready=0; fi
    [ "$ready" -ge 2 ] && break
    sleep 1
  done
  [ "$ready" -ge 2 ] || return 1
  printf '%s' "$cid"
}

echo "1. cluster A: a stand-in live instance (roles + a granted table)"
A=$(start) || { bad "could not start cluster A"; exit 1; }
docker exec "$A" psql -U drill -d postgres -q \
  -c "CREATE ROLE opsroom LOGIN PASSWORD 'x'" \
  -c "CREATE ROLE web_anon NOLOGIN" \
  -c "CREATE DATABASE opsroom OWNER opsroom" >/dev/null 2>&1
docker exec "$A" psql -U drill -d opsroom -q \
  -c "CREATE SCHEMA registry AUTHORIZATION opsroom" \
  -c "CREATE TABLE registry.sources(id int primary key)" \
  -c "INSERT INTO registry.sources VALUES (1),(2)" \
  -c "CREATE TABLE alembic_version(version_num varchar(32) primary key)" \
  -c "INSERT INTO alembic_version VALUES ('0013_proof')" \
  -c "GRANT USAGE ON SCHEMA registry TO web_anon" \
  -c "GRANT SELECT ON registry.sources TO web_anon" \
  -c "ALTER DEFAULT PRIVILEGES IN SCHEMA registry GRANT SELECT ON TABLES TO web_anon" >/dev/null 2>&1
docker exec "$A" pg_dump -U drill -d opsroom > "$T/product.sql" 2>/dev/null
docker exec "$A" pg_dumpall -U drill --roles-only > "$T/roles.sql" 2>/dev/null
[ -s "$T/product.sql" ] && ok "product dump taken ($(wc -l < "$T/product.sql") lines)" || bad "no product dump"
grep -qE 'CREATE ROLE (opsroom|web_anon)' "$T/roles.sql" \
  && ok "roles file has the CREATE ROLE statements ($(grep -c 'CREATE ROLE' "$T/roles.sql") roles)" \
  || bad "roles file carries no CREATE ROLE"
# The premise of the whole finding, asserted rather than assumed:
grep -q 'TO web_anon' "$T/product.sql" \
  && ok "the product dump GRANTs to web_anon" || bad "dump has no GRANT to web_anon — premise gone"
grep -q 'CREATE ROLE' "$T/product.sql" \
  && bad "the product dump DOES carry CREATE ROLE — the finding would not apply" \
  || ok "the product dump carries NO CREATE ROLE (this is the gap)"

echo "2. cluster B: fresh, product dump alone, ON_ERROR_STOP -> must FAIL"
B=$(start) || { bad "could not start cluster B"; exit 1; }
docker exec "$B" psql -U drill -d postgres -qc 'CREATE DATABASE opsroom' >/dev/null 2>&1
if docker exec -i "$B" psql -U drill -d opsroom -q -v ON_ERROR_STOP=1 < "$T/product.sql" >"$T/b.log" 2>&1; then
  bad "the replay SUCCEEDED without roles — the roles file would not be load-bearing"
else
  err=$(grep -m1 ERROR "$T/b.log" | cut -c1-90)
  printf '      %s\n' "$err"
  printf '%s' "$err" | grep -qi 'role .* does not exist' \
    && ok "failed exactly as reported: the role does not exist" \
    || ok "failed (different first error, still a failure): ${err:-none}"
fi
# AND THE ROWS ARE NOT THERE — the failure is not cosmetic.
n=$(docker exec "$B" psql -U drill -d opsroom -tAc 'SELECT count(*) FROM registry.sources' 2>/dev/null | tr -d '[:space:]')
[ "${n:-x}" = "2" ] && bad "rows landed anyway ($n) — the failure was cosmetic" \
  || ok "the restored database does NOT have the rows (got: ${n:-nothing})"

echo "3. cluster C: fresh, ROLES FIRST, then the dump -> must PASS"
C=$(start) || { bad "could not start cluster C"; exit 1; }
docker exec -i "$C" psql -U drill -d postgres -q < "$T/roles.sql" >/dev/null 2>&1 || true
for role in opsroom web_anon; do
  [ "$(docker exec "$C" psql -U drill -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='$role'" 2>/dev/null | tr -d '[:space:]')" = "1" ] \
    && ok "role $role exists after loading the roles file" || bad "role $role MISSING after the roles file"
done
docker exec "$C" psql -U drill -d postgres -qc 'CREATE DATABASE opsroom' >/dev/null 2>&1
if docker exec -i "$C" psql -U drill -d opsroom -q -v ON_ERROR_STOP=1 < "$T/product.sql" >"$T/c.log" 2>&1; then
  ok "product dump replayed clean under ON_ERROR_STOP"
else
  bad "roles-first replay FAILED: $(grep -m1 ERROR "$T/c.log" | cut -c1-100)"
fi
v=$(docker exec "$C" psql -U drill -d opsroom -tAc 'SELECT version_num FROM alembic_version' 2>/dev/null | tr -d '[:space:]')
[ "$v" = "0013_proof" ] && ok "schema revision read back: $v" || bad "alembic_version not readable (got: ${v:-nothing})"
n=$(docker exec "$C" psql -U drill -d opsroom -tAc 'SELECT count(*) FROM registry.sources' 2>/dev/null | tr -d '[:space:]')
[ "${n:-0}" = "2" ] && ok "registry.sources has $n rows after restore" || bad "rows missing (got: ${n:-nothing})"

echo; printf '%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" = 0 ]
