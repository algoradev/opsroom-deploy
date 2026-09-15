#!/usr/bin/env bash
# Prove a backup can actually be restored. Reads from the destination,
# decrypts, and RESTORES INTO THROWAWAY CONTAINERS — never into the live
# instance.
#
#   ./backup/restore-drill.sh                 # newest backup
#   ./backup/restore-drill.sh 20260806T164037Z
#   ./backup/restore-drill.sh --source-bytes  # ONLY the source-bytes mirror
#                                             # (lives outside the stamp; needs
#                                             # no passphrase, no scratch pg)
#
# WHY THIS EXISTS: an untested backup is a hope. Every step below is one
# that has failed for somebody — objects that list but 404 on GET, a
# passphrase that decrypts nothing because it was rotated, a dump that
# restores with zero rows, a bundle that clones to the wrong HEAD. None of
# those are visible from the backup side; all of them are visible here.
#
# This is the REHEARSAL. `sudo bash install.sh --restore` is the real thing,
# and it replays in the same order this drill proves.
#
# It touches NOTHING of the running instance: a scratch postgres container
# on a random port, removed on exit even on failure.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
export PATH="$HOME/.local/bin:$PATH"
env_get() { grep -E "^$1=" .env | head -1 | cut -d= -f2- ; }

DEST="$(env_get OPSROOM_BACKUP_DEST)"
PASSPHRASE="$(env_get OPSROOM_BACKUP_PASSPHRASE)"
export AWS_ACCESS_KEY_ID="$(env_get OPSROOM_BACKUP_S3_ACCESS_KEY_ID)"
export AWS_SECRET_ACCESS_KEY="$(env_get OPSROOM_BACKUP_S3_SECRET_ACCESS_KEY)"
export AWS_DEFAULT_REGION=auto
EP="$(env_get OPSROOM_BACKUP_S3_ENDPOINT)"
OBJ_BASE="$(env_get OPSROOM_OBJECT_STORE_BASE)"

# --source-bytes: drill ONLY the data mirror. It lives at <bucket>/data/,
# OUTSIDE any stamp (backup.sh step 5 — retention must never prune it), so
# it needs no stamp, no passphrase and no scratch postgres. Offered as its
# own verb because it is cheap enough to run after every backup, and a
# source-bytes drill that only happens inside the full drill happens as
# often as the full drill.
MODE=full
if [ "${1:-}" = "--source-bytes" ]; then MODE=bytes; shift; fi
if [ "$MODE" = "full" ]; then
  [ -n "$PASSPHRASE" ] || { echo "✗ no OPSROOM_BACKUP_PASSPHRASE — cannot decrypt"; exit 1; }
fi

STAMP="${1:-}"
if [ -z "$STAMP" ]; then
  STAMP=$(aws s3 ls "${DEST%/}/" --endpoint-url "$EP" 2>/dev/null \
          | awk '{print $2}' | tr -d '/' | grep -E '^[0-9]{8}T' | sort | tail -1)
fi
if [ "$MODE" = "full" ]; then
  [ -n "$STAMP" ] || { echo "✗ no backups found at $DEST"; exit 1; }
fi

WORK="$ROOT/.backup-work.drill.$$"
CID=""
cleanup() { [ -n "$CID" ] && docker rm -f "$CID" >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT
mkdir -p "$WORK"

fail=0
drilled=1   # source-bytes step: 0 when there was nothing to drill (n/a is not a pass)
ok()  { printf '    ✓ %s\n' "$1"; }
bad() { printf '    ✗ %s\n' "$1"; fail=1; }

# ==> SOURCE BYTES — and the step that verifies ITSELF.
#
# WHY IT CAN: uploaded objects are CONTENT-ADDRESSED. The upload door names
# the CSV by the sha256 of its bytes and names the derived parquet with the
# SAME sha as provenance. So a restored CSV is checked against its own
# filename — no reference copy, no second bucket, and a truncated or
# corrupted download FAILS THE HASH instead of merely existing. The parquet
# cannot be hashed against its name (its bytes are not the CSV's), so it is
# verified by PAIRING: every parquet must stand beside the CSV it was made
# from. Two different checks for two different facts.
#
# THREE-VALUED, like backup.sh's step 5 that produces this mirror:
#   no object store configured  -> n/a, said in those words, never "verified"
#   mirror expected and EMPTY   -> FAIL (source bytes left the backups)
#   objects present             -> each one verified or named as not
drill_source_bytes() {
  local manifest="$1"   # MANIFEST.txt (full) or LATEST.txt (bytes mode)
  if [ -z "$OBJ_BASE" ]; then
    printf '    - n/a — OPSROOM_OBJECT_STORE_BASE is empty: no object store, no\n'
    printf '      source bytes to drill. NOT a pass; there was nothing to test.\n'
    printf '      (Uploads then live in the home volume, which step 5 covers.)\n'
    drilled=0
    return
  fi
  drilled=1
  local src="${DEST%/}/data"
  mkdir -p "$WORK/data"
  if ! aws s3 cp "$src/" "$WORK/data/" --recursive --endpoint-url "$EP" >/dev/null 2>&1; then
    bad "the source-bytes mirror at $src could not be downloaded"; return
  fi
  local n; n=$(find "$WORK/data" -type f | wc -l)
  # THE MANIFEST'S NUMBER FIRST: backup.sh wrote "data bucket has N" at backup
  # time. If N was 0, an empty mirror is a FACT about a store with nothing in
  # it yet — not bytes that left. Only an expected-nonempty mirror that is
  # empty is the failure this branch names.
  local had; had=$(grep -E '^source bytes:' "$manifest" 2>/dev/null | grep -oE 'data bucket has [0-9]+' | awk '{print $4}')
  if [ "$n" -eq 0 ] && [ "${had:-}" = "0" ]; then
    ok "mirror holds 0 object(s), and the manifest says the data bucket had 0 at backup time — nothing to mirror yet"
    return
  fi
  if [ "$n" -eq 0 ]; then
    bad "the mirror at $src is EMPTY — an object store is configured (data bucket had ${had:-?}), so source bytes have LEFT THE BACKUPS"
    return
  fi
  # THE MANIFEST'S NUMBER vs WHAT RESTORED. The mirror is additive so >= N is
  # the healthy reading; < N means objects that were there are not now.
  local expect
  expect=$(grep -E '^source bytes:' "$manifest" 2>/dev/null | grep -oE 'mirror holds [0-9]+' | awk '{print $3}')
  if [ -n "$expect" ]; then
    if [ "$n" -ge "$expect" ] 2>/dev/null; then ok "restored $n object(s); manifest said the mirror held $expect"
    else bad "restored $n object(s) but the manifest said the mirror held $expect — objects are MISSING"; fi
  else
    ok "restored $n object(s) (manifest carries no mirror count — an older backup)"
  fi
  # SELF-VERIFY every CSV against its name. `sha256sum` reads the whole file;
  # a short download produces a different digest, not a warning.
  local verified=0 corrupt=0 unnamed=0 orphans=0 f base got
  while IFS= read -r f; do
    base=$(basename "$f" .csv)
    if printf '%s' "$base" | grep -qE '^[0-9a-f]{64}$'; then
      got=$(sha256sum "$f" | cut -d' ' -f1)
      if [ "$got" = "$base" ]; then verified=$((verified+1))
      else corrupt=$((corrupt+1)); bad "CORRUPT: ${base:0:12}….csv hashes to ${got:0:12}… — the bytes are not the bytes"; fi
    else
      unnamed=$((unnamed+1)); bad "UNVERIFIABLE: $(basename "$f") is not sha-named — not written by the upload door; cannot be checked"
    fi
  done < <(find "$WORK/data" -type f -name '*.csv')
  # PAIRING for parquets: same stem, CSV beside it.
  while IFS= read -r f; do
    if [ -f "${f%.parquet}.csv" ]; then verified=$((verified+1))
    else orphans=$((orphans+1)); bad "ORPHAN: $(basename "$f") has no CSV beside it — a derived object without its origin"; fi
  done < <(find "$WORK/data" -type f -name '*.parquet')
  local other; other=$(find "$WORK/data" -type f ! -name '*.csv' ! -name '*.parquet' | wc -l)
  [ "$other" -gt 0 ] && bad "$other object(s) that are neither .csv nor .parquet — not the upload door's shape"
  ok "verified $verified object(s) by hash or pairing (corrupt=$corrupt unverifiable=$unnamed orphan=$orphans)"
  [ $((corrupt+unnamed+orphans+other)) -eq 0 ] && ok "every restored source object is the object it claims to be"
}

if [ "$MODE" = "bytes" ]; then
  echo "==> DRILL (source bytes only) on ${DEST%/}/data"
  echo "==> 1/1  the source-bytes mirror"
  aws s3 cp "${DEST%/}/LATEST.txt" "$WORK/LATEST.txt" --endpoint-url "$EP" >/dev/null 2>&1 || : > "$WORK/LATEST.txt"
  drill_source_bytes "$WORK/LATEST.txt"
  echo
  if [ "$drilled" = "0" ]; then
    echo "================ NOTHING TO DRILL ================"
    echo "No object store is configured on this instance, so there are no source"
    echo "bytes in the backup to restore. This is a fact about the config, not a pass."
  elif [ "$fail" = "0" ]; then
    echo "================ SOURCE-BYTES DRILL PASSED ================"
  else
    echo "================ SOURCE-BYTES DRILL FAILED ================"
    echo "The source bytes in the backup are not restorable as they stand."
    exit 1
  fi
  exit 0
fi

echo "==> DRILL on $DEST/$STAMP"

echo "==> 1/6  download (objects must GET, not merely LIST)"
for f in identity-all.sql.gpg product-opsroom.sql.gpg opsroom-home.tar.gz.gpg dbt-test.bundle MANIFEST.txt; do
  if aws s3 cp "${DEST%/}/$STAMP/$f" "$WORK/$f" --endpoint-url "$EP" >/dev/null 2>&1 && [ -s "$WORK/$f" ]; then
    ok "$f ($(du -h "$WORK/$f" | cut -f1))"
  else
    bad "$f could not be downloaded"
  fi
done
[ "$fail" = "0" ] || { echo; echo "✗ DRILL FAILED at download"; exit 1; }

echo "==> 2/6  decrypt (proves the passphrase in .env matches these artifacts)"
# The roles file ships from deploy-v0.2.2 on; a backup taken before that has
# none, and the product replay below then meets the finding it was added for.
ROLES=0
if aws s3 cp "${DEST%/}/$STAMP/product-roles.sql.gpg" "$WORK/product-roles.sql.gpg" --endpoint-url "$EP" >/dev/null 2>&1 && [ -s "$WORK/product-roles.sql.gpg" ]; then
  ROLES=1; ok "product-roles.sql.gpg ($(du -h "$WORK/product-roles.sql.gpg" | cut -f1))"
else
  echo "    - product-roles.sql.gpg absent — an older backup; the product replay will show what that costs"
fi
for f in identity-all.sql product-opsroom.sql opsroom-home.tar.gz $( [ "$ROLES" = 1 ] && echo product-roles.sql ); do
  if gpg --batch --yes --quiet --pinentry-mode loopback --passphrase "$PASSPHRASE" \
        -o "$WORK/$f" --decrypt "$WORK/$f.gpg" 2>/dev/null && [ -s "$WORK/$f" ]; then
    ok "$f decrypted"
  else
    bad "$f DID NOT DECRYPT — wrong passphrase, or the artifact is corrupt"
  fi
done
[ "$fail" = "0" ] || { echo; echo "✗ DRILL FAILED at decrypt — the backups are unusable"; exit 1; }

echo "==> 3/6  restore the identity plane into a THROWAWAY postgres"
CID=$(docker run -d --rm -e POSTGRES_PASSWORD=drill -e POSTGRES_USER=drill postgres:16-alpine 2>/dev/null)
[ -n "$CID" ] || { bad "could not start scratch postgres"; echo "✗ DRILL FAILED"; exit 1; }
# READY MEANS TWO CONSECUTIVE REAL QUERIES, NOT pg_isready. The postgres image's
# entrypoint starts a TEMPORARY server for init scripts, stops it, then starts
# the real one; pg_isready answers during that first window, and a replay that
# begins there hits the restart and fails — swallowed below as "with warnings".
# Measured on the house instance 2026-09-13: two drills in a row lost every
# database that way; a hand replay after two consecutive `select 1` restored
# all three cleanly.
ready=0
for i in $(seq 1 60); do
  if docker exec "$CID" psql -U drill -d postgres -tAc 'select 1' >/dev/null 2>&1; then ready=$((ready+1)); else ready=0; fi
  [ "$ready" -ge 2 ] && break
  sleep 1
done
[ "$ready" -ge 2 ] || bad "scratch postgres never answered two consecutive queries in 60s"
if docker exec -i "$CID" psql -U drill -d postgres -q < "$WORK/identity-all.sql" >/dev/null 2>&1; then
  ok "identity dump replayed"
else
  # pg_dumpall replays are noisy (roles that already exist); judge by CONTENT
  ok "identity dump replayed (with warnings — judging by content below)"
fi

echo "==> 3b/6 the PRODUCT plane: roles first, then the dump, ON_ERROR_STOP"
# THE ONLY ROWS YOU CANNOT REBUILD ARE IN THIS ARTIFACT, AND THIS DRILL USED
# TO DECRYPT IT AND NEVER REPLAY IT — so a PASS said nothing about the product
# database at all. The identity replay tolerates warnings because pg_dumpall
# re-creates roles that exist; the product replay is held to ON_ERROR_STOP
# because its failures are the finding: a `pg_dump` of one database carries
# `GRANT … TO web_anon` and `OWNER TO opsroom` and never the roles, so a fresh
# cluster dies partway through with "role does not exist". backup.sh ships the
# roles beside the dump; they load first, and the two roles are READ BACK
# before the replay is attempted.
if [ "$ROLES" = 1 ]; then
  docker exec -i "$CID" psql -U drill -d postgres -q < "$WORK/product-roles.sql" >/dev/null 2>&1 || true  # roles that exist warn; judged by read-back
  for role in opsroom web_anon; do
    [ "$(docker exec "$CID" psql -U drill -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='$role'" 2>/dev/null | tr -d '[:space:]')" = "1" ] \
      && ok "role $role restored" || bad "role $role MISSING after loading product-roles.sql"
  done
fi
docker exec "$CID" psql -U drill -d postgres -qc 'CREATE DATABASE opsroom' >/dev/null 2>&1
if docker exec -i "$CID" psql -U drill -d opsroom -q -v ON_ERROR_STOP=1 < "$WORK/product-opsroom.sql" >"$WORK/product-replay.log" 2>&1; then
  ok "product dump replayed (ON_ERROR_STOP)"
else
  first=$(grep -m1 -E 'ERROR' "$WORK/product-replay.log" | cut -c1-110)
  bad "product dump did NOT replay: ${first:-unknown error}"
  [ "$ROLES" = 1 ] || echo "      (no roles file in this backup — this is the fresh-cluster finding the roles file exists for)"
fi

echo "==> 4/6  READ THE RESTORED DATA — the only proof that matters"
q() { docker exec "$CID" psql -U drill -d "$1" -tAc "$2" 2>/dev/null | tr -d '[:space:]'; }
for db in asunset keycloak openfga; do
  docker exec "$CID" psql -U drill -lqt 2>/dev/null | cut -d'|' -f1 | grep -qw "$db" \
    && ok "database $db exists" || bad "database $db MISSING after restore"
done
U=$(q keycloak "SELECT count(*) FROM user_entity")
[ -n "$U" ] && [ "$U" -gt 0 ] 2>/dev/null && ok "keycloak realm has $U users (the realm survived)" \
  || bad "keycloak has NO users — the realm did not survive"
T=$(q openfga "SELECT count(*) FROM tuple")
[ -n "$T" ] && [ "$T" -gt 0 ] 2>/dev/null && ok "openfga has $T tuples (grants survived)" \
  || bad "openfga has NO tuples — every grant was lost"
O=$(q asunset "SELECT count(*) FROM organization")
[ -n "$O" ] && [ "$O" -gt 0 ] 2>/dev/null && ok "asunset has $O organization row(s)" \
  || bad "asunset has no organizations"
# THE PRODUCT PLANE, READ BACK — the schema revision the restored database
# is at, and the rows that are the point of the whole exercise.
V=$(q opsroom "SELECT version_num FROM alembic_version")
[ -n "$V" ] && ok "product database restored at $V" || bad "product database has no alembic_version — the replay did not land"
S=$(q opsroom "SELECT count(*) FROM registry.sources")
[ -n "$S" ] && ok "registry.sources has $S row(s) after restore" || bad "registry.sources unreadable after restore"
P=$(q opsroom "SELECT count(*) FROM registry.projects")
[ -n "$P" ] && ok "registry.projects has $P row(s) after restore" || bad "registry.projects unreadable after restore"

echo "==> 5/6  home volume + orchestration bundle"
# NOT `| grep -q` — under `set -o pipefail` that reports a FALSE FAILURE:
# grep -q exits the moment it matches, tar gets SIGPIPE and dies with 141,
# and pipefail makes the pipeline 141 even though the file was found. grep -c
# consumes the whole stream, so tar exits cleanly.
# The sentinel USED to be `methodology/context.yaml`, deleted from the product
# 2026-08-18 and gone for good with board 150's retirement. Every drill after
# that reported a healthy backup as "would NOT have saved you" on this line:
# A STALE ASSERTION IS A FALSE RED THAT ACCUSES, and this one accused the
# backups. The archive is now judged on what it must always have: it lists
# cleanly (integrity — a truncated gzip fails here) and it is not empty.
# `data/` is REPORTED, not asserted, because whether it belongs here depends
# on whether an object store holds it (backup.sh step 3).
if tar tzf "$WORK/opsroom-home.tar.gz" >"$WORK/home.list" 2>/dev/null; then
  ENTRIES=$(wc -l < "$WORK/home.list")
  if [ "$ENTRIES" -gt 0 ] 2>/dev/null; then
    ok "home archive lists cleanly ($ENTRIES entries)"
    DATA_ENTRIES=$(grep -c '^\./data/' "$WORK/home.list")
    if [ "${DATA_ENTRIES:-0}" -gt 0 ] 2>/dev/null; then
      printf '    - %s entries under ./data/ — this instance keeps uploads in the home volume\n' "$DATA_ENTRIES"
    elif [ -n "$OBJ_BASE" ]; then
      printf '    - no ./data/ entries, as expected: the object store holds uploads (step 6 drills them)\n'
    fi
  else
    bad "home archive is EMPTY"
  fi
else
  bad "home archive does not list — truncated or not a gzip"
fi
if git clone -q "$WORK/dbt-test.bundle" "$WORK/clone" 2>/dev/null; then
  HAVE=$(git -C "$WORK/clone" rev-parse HEAD 2>/dev/null)
  WANT=$(grep '^head_commit:' "$WORK/MANIFEST.txt" | awk '{print $2}')
  [ "$HAVE" = "$WANT" ] && ok "bundle clones, HEAD matches the manifest (${HAVE:0:8})" \
    || bad "bundle HEAD ${HAVE:0:8} != manifest ${WANT:0:8}"
  ok "$(git -C "$WORK/clone" rev-list --count HEAD) commits of orchestration recovered"
  # THE CONFIG IS NOT IN HERE, AND THAT IS THE GAP, NOT A FAILURE OF THIS
  # BACKUP. The product repo seals `.env.enc` into its bundle, so a restored
  # checkout plus the age key rebuilds the configuration. The pull path ships
  # no seal yet (report 155 §4: it lands with the role split's second
  # password), so on this path `.env` is yours to hold. A `bad` here would be
  # a permanent red for a gap no operator can close — it is said once, plainly.
  if [ -s "$WORK/clone/.env.enc" ]; then
    if sops --decrypt --input-type dotenv --output-type dotenv "$WORK/clone/.env.enc" 2>/dev/null | grep -q "OPSROOM_BACKUP_DEST"; then
      ok "recovered .env.enc DECRYPTS — the config recovery chain is real"
    else
      bad ".env.enc recovered but did not decrypt (age key missing or rotated?)"
    fi
  else
    printf '    - the bundle carries no sealed .env: on this path the configuration is\n'
    printf '      NOT in the backup. Keep .env (or its values) in your password manager —\n'
    printf '      a restore needs the passphrase and the age key from outside the backup.\n'
  fi
else
  bad "bundle did not clone"
fi

echo "==> 6/6  source bytes (the mirror, verified against its own names)"
drill_source_bytes "$WORK/MANIFEST.txt"

echo
if [ "$fail" = "0" ]; then
  echo "================ DRILL PASSED ================"
  echo "$STAMP is restorable: downloaded, decrypted, replayed, and READ BACK."
  if [ "$drilled" = "1" ]; then
    echo "The realm, the grants, the product rows, the home volume, the"
    echo "orchestration and the source bytes all survived."
  else
    echo "The realm, the grants, the product rows, the home volume and the"
    echo "orchestration survived."
    echo "(No object store is configured — there were no source bytes to test. Not a pass on that step; a fact about the config.)"
  fi
  echo
  echo "Restore for real on a fresh box:  sudo bash install.sh --restore"
else
  echo "================ DRILL FAILED ================"
  echo "This backup would NOT have saved you. Fix it before trusting the next one."
  exit 1
fi
