#!/usr/bin/env bash
# Prove a backup can actually be restored. Reads from the destination,
# decrypts, and RESTORES INTO THROWAWAY CONTAINERS — never into the live
# instance.
#
#   ./backup/restore-drill.sh                 # newest backup
#   ./backup/restore-drill.sh 20260806T164037Z
#
# WHY THIS EXISTS: an untested backup is a hope. Every step below is one
# that has failed for somebody — objects that list but 404 on GET, a
# passphrase that decrypts nothing because it was rotated, a dump that
# restores with zero rows, a bundle that clones to the wrong HEAD. None of
# those are visible from the backup side; all of them are visible here.
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
[ -n "$PASSPHRASE" ] || { echo "✗ no OPSROOM_BACKUP_PASSPHRASE — cannot decrypt"; exit 1; }

STAMP="${1:-}"
if [ -z "$STAMP" ]; then
  STAMP=$(aws s3 ls "${DEST%/}/" --endpoint-url "$EP" 2>/dev/null \
          | awk '{print $2}' | tr -d '/' | grep -E '^[0-9]{8}T' | sort | tail -1)
fi
[ -n "$STAMP" ] || { echo "✗ no backups found at $DEST"; exit 1; }

WORK="$ROOT/.backup-work.drill.$$"
CID=""
cleanup() { [ -n "$CID" ] && docker rm -f "$CID" >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT
mkdir -p "$WORK"

fail=0
ok()  { printf '    ✓ %s\n' "$1"; }
bad() { printf '    ✗ %s\n' "$1"; fail=1; }

echo "==> DRILL on $DEST/$STAMP"

echo "==> 1/5  download (objects must GET, not merely LIST)"
for f in identity-all.sql.gpg product-opsroom.sql.gpg opsroom-home.tar.gz.gpg dbt-test.bundle MANIFEST.txt; do
  if aws s3 cp "${DEST%/}/$STAMP/$f" "$WORK/$f" --endpoint-url "$EP" >/dev/null 2>&1 && [ -s "$WORK/$f" ]; then
    ok "$f ($(du -h "$WORK/$f" | cut -f1))"
  else
    bad "$f could not be downloaded"
  fi
done
[ "$fail" = "0" ] || { echo; echo "✗ DRILL FAILED at download"; exit 1; }

echo "==> 2/5  decrypt (proves the passphrase in .env matches these artifacts)"
for f in identity-all.sql product-opsroom.sql opsroom-home.tar.gz; do
  if gpg --batch --yes --quiet --pinentry-mode loopback --passphrase "$PASSPHRASE" \
        -o "$WORK/$f" --decrypt "$WORK/$f.gpg" 2>/dev/null && [ -s "$WORK/$f" ]; then
    ok "$f decrypted"
  else
    bad "$f DID NOT DECRYPT — wrong passphrase, or the artifact is corrupt"
  fi
done
[ "$fail" = "0" ] || { echo; echo "✗ DRILL FAILED at decrypt — the backups are unusable"; exit 1; }

echo "==> 3/5  restore the identity plane into a THROWAWAY postgres"
CID=$(docker run -d --rm -e POSTGRES_PASSWORD=drill -e POSTGRES_USER=drill postgres:16-alpine 2>/dev/null)
[ -n "$CID" ] || { bad "could not start scratch postgres"; echo "✗ DRILL FAILED"; exit 1; }
for i in $(seq 1 40); do docker exec "$CID" pg_isready -U drill >/dev/null 2>&1 && break; sleep 1; done
if docker exec -i "$CID" psql -U drill -d postgres -q < "$WORK/identity-all.sql" >/dev/null 2>&1; then
  ok "identity dump replayed"
else
  # pg_dumpall replays are noisy (roles that already exist); judge by CONTENT
  ok "identity dump replayed (with warnings — judging by content below)"
fi

echo "==> 4/5  READ THE RESTORED DATA — the only proof that matters"
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

echo "==> 5/5  home volume + repo bundle"
# NOT `| grep -q` — under `set -o pipefail` that reports a FALSE FAILURE:
# grep -q exits the moment it matches, tar gets SIGPIPE and dies with 141,
# and pipefail makes the pipeline 141 even though the file was found. This
# drill reported a healthy backup as broken on its first run because of
# exactly that. grep -c consumes the whole stream, so tar exits cleanly.
ENTRIES=$(tar tzf "$WORK/opsroom-home.tar.gz" 2>/dev/null | wc -l)
HAS_CTX=$(tar tzf "$WORK/opsroom-home.tar.gz" 2>/dev/null | grep -c "methodology/context.yaml")
if [ "${HAS_CTX:-0}" -gt 0 ] 2>/dev/null; then
  ok "home archive contains methodology/context.yaml ($ENTRIES entries)"
else
  bad "home archive missing methodology/context.yaml"
fi
if git clone -q "$WORK/dbt-test.bundle" "$WORK/clone" 2>/dev/null; then
  # Recovery chain (report 112): the bundle carries .env.enc, so a restored
  # repo + the age key (password manager) reconstructs the CONFIG too — the
  # link that used to be "remember what was in the file".
  if [ -s "$WORK/clone/.env.enc" ]; then
    if sops --decrypt --input-type dotenv --output-type dotenv          "$WORK/clone/.env.enc" 2>/dev/null | grep -q "OPSROOM_BACKUP_DEST"; then
      ok "recovered .env.enc DECRYPTS — the config recovery chain is real"
    else
      bad ".env.enc recovered but did not decrypt (age key missing or rotated?)"
    fi
  else
    bad "bundle carries no .env.enc — seal + commit it (./deploy/secrets.sh seal)"
  fi
  HAVE=$(git -C "$WORK/clone" rev-parse HEAD 2>/dev/null)
  WANT=$(grep '^head_commit:' "$WORK/MANIFEST.txt" | awk '{print $2}')
  [ "$HAVE" = "$WANT" ] && ok "bundle clones, HEAD matches the manifest (${HAVE:0:8})" \
    || bad "bundle HEAD ${HAVE:0:8} != manifest ${WANT:0:8}"
  ok "$(git -C "$WORK/clone" rev-list --count HEAD) commits recovered"
else
  bad "bundle did not clone"
fi

echo
if [ "$fail" = "0" ]; then
  echo "================ DRILL PASSED ================"
  echo "$STAMP is restorable: downloaded, decrypted, replayed, and READ BACK."
  echo "The realm, the grants, the content tree and the repo all survived."
else
  echo "================ DRILL FAILED ================"
  echo "This backup would NOT have saved you. Fix it before trusting the next one."
  exit 1
fi
