#!/usr/bin/env bash
# The instance backup. Reads its configuration from .env.
#
#   ./backup/backup.sh              # to OPSROOM_BACKUP_DEST
#   ./backup/backup.sh file:///tmp/x   # override the destination
#
# ONE SCRIPT, TWO WORLDS, BY URL ONLY: `file://` for a local rehearsal,
# `s3://` for anything real. That is deliberate — a backup practice you only
# ever exercise against a local directory tests none of the parts that
# actually fail (credentials, a truncated upload, encryption, retention,
# restoring from somewhere else). Dev and prod differ by a URL, so the path
# that runs in production is the path that has been rehearsed.
#
# WHAT A COMPLETE BACKUP IS:
#   1. identity plane — ALL THREE dbs via pg_dumpall (asunset, keycloak,
#      openfga). `pg_dump asunset` alone loses the realm and every grant.
#   2. product plane — the opsroom database.
#   3. instance home — the opsroom_home volume: content tree, methodology,
#      context.yaml. In neither database.
#   4. the repo — `git bundle --all`. The checkout is on the host
#      filesystem, so it is in no other artifact here.
# Dumps are gpg-encrypted before they leave the machine. The repo bundle is
# not: it is source, and encrypting it would make the disaster-recovery path
# depend on the same secret twice.
#
# RESTORE ORDER (not the backup order): identity plane FIRST — Keycloak and
# OpenFGA must boot before anything validates — product second, then doctor
# (report 91 §7, Juniper's amendment).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
[ -f .env ] || { echo "✗ no root .env"; exit 1; }

env_get() { grep -E "^$1=" .env | head -1 | cut -d= -f2- ; }

DEST="${1:-$(env_get OPSROOM_BACKUP_DEST)}"
PASSPHRASE="$(env_get OPSROOM_BACKUP_PASSPHRASE)"
RETAIN="$(env_get OPSROOM_BACKUP_RETAIN_DAYS)"; RETAIN="${RETAIN:-30}"
export AWS_ACCESS_KEY_ID="$(env_get OPSROOM_BACKUP_S3_ACCESS_KEY_ID)"
export AWS_SECRET_ACCESS_KEY="$(env_get OPSROOM_BACKUP_S3_SECRET_ACCESS_KEY)"
export AWS_DEFAULT_REGION=auto
S3_ENDPOINT="$(env_get OPSROOM_BACKUP_S3_ENDPOINT)"

[ -n "$DEST" ] || { echo "✗ no OPSROOM_BACKUP_DEST and no argument"; exit 1; }
if [ "$DEST" = "none" ]; then
  echo "OPSROOM_BACKUP_DEST=none — backups deliberately not configured. Nothing to do."
  exit 0
fi
# REFUSE rather than silently write plaintext. An unencrypted identity dump
# is every credential and every grant sitting in object storage.
[ -n "$PASSPHRASE" ] || { echo "✗ OPSROOM_BACKUP_PASSPHRASE is unset — refusing to write unencrypted dumps"; exit 1; }

case "$DEST" in
  s3://*) MODE=s3; [ -n "$S3_ENDPOINT" ] || { echo "✗ s3 destination needs OPSROOM_BACKUP_S3_ENDPOINT"; exit 1; }
          command -v aws >/dev/null || { echo "✗ aws cli not found"; exit 1; } ;;
  file://*) MODE=file; LOCAL="${DEST#file://}"; mkdir -p "$LOCAL" || exit 1 ;;
  /*) MODE=file; LOCAL="$DEST"; mkdir -p "$LOCAL" || exit 1 ;;
  *) echo "✗ destination must be s3://bucket[/prefix], file:///path, or /path"; exit 1 ;;
esac

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
# The staging dir lives INSIDE THE REPO, not in /tmp, because the home-volume
# step bind-mounts it into a container and docker cannot always mount a
# host /tmp path (it fails SILENTLY — no error, no file, and the step just
# reports failure with nothing to read). Repo-local is mountable everywhere
# this runs. .gitignored, and removed on exit including on failure, because
# the dumps are plaintext until the encrypt step.
WORK="$ROOT/.backup-work.$$"
mkdir -p "$WORK" || exit 1
trap 'rm -rf "$WORK"' EXIT

COMPOSE=(docker compose --env-file release.env --env-file .env)
SU=$(env_get POSTGRES_SUPERUSER)

fail=0
note() { printf '    %-32s %s\n' "$1" "$2"; }
enc() { # plaintext -> .gpg, then shred the plaintext
  gpg --batch --yes --symmetric --cipher-algo AES256 --pinentry-mode loopback \
      --passphrase "$PASSPHRASE" -o "$1.gpg" "$1" 2>/dev/null && rm -f "$1"; }

echo "==> backup $STAMP -> $DEST"

echo "==> 1/4  identity plane (all three databases)"
if "${COMPOSE[@]}" exec -T postgres pg_dumpall -U "$SU" > "$WORK/identity-all.sql" 2>/dev/null \
   && [ -s "$WORK/identity-all.sql" ]; then
  # VERIFY THE CONTENT, not the exit code. A pg_dumpall that connected but
  # skipped a database exits 0 and produces a file — the failure this whole
  # check exists for is a dump that looks fine and has no realm in it.
  for db in asunset keycloak openfga; do
    grep -qE "CREATE DATABASE $db|\\\\connect $db" "$WORK/identity-all.sql" \
      && note "  contains $db" "yes" || { note "  contains $db" "*** NO ***"; fail=1; }
  done
  note "identity-all.sql" "$(du -h "$WORK/identity-all.sql" | cut -f1) plaintext"
  enc "$WORK/identity-all.sql" && note "  encrypted" "$(du -h "$WORK/identity-all.sql.gpg" | cut -f1)"
else
  note "identity-all.sql" "*** FAILED ***"; fail=1
fi

echo "==> 2/4  product plane"
if "${COMPOSE[@]}" exec -T opsroom-postgres pg_dump -U opsroom -d opsroom > "$WORK/product-opsroom.sql" 2>/dev/null \
   && [ -s "$WORK/product-opsroom.sql" ]; then
  enc "$WORK/product-opsroom.sql" && note "product-opsroom.sql.gpg" "$(du -h "$WORK/product-opsroom.sql.gpg" | cut -f1)"
else
  note "product-opsroom.sql" "*** FAILED ***"; fail=1
fi

echo "==> 3/4  instance home volume"
VOL=$(docker volume ls --format '{{.Name}}' | grep -m1 'opsroom_home')
if [ -n "$VOL" ] && docker run --rm -v "$VOL":/src:ro -v "$WORK":/out alpine \
     tar czf /out/opsroom-home.tar.gz -C /src . 2>/dev/null && [ -s "$WORK/opsroom-home.tar.gz" ]; then
  enc "$WORK/opsroom-home.tar.gz" && note "opsroom-home.tar.gz.gpg ($VOL)" "$(du -h "$WORK/opsroom-home.tar.gz.gpg" | cut -f1)"
else
  note "opsroom-home.tar.gz" "*** FAILED ***"; fail=1
fi

echo "==> 4/4  repo bundle (source — deliberately NOT encrypted)"
if git bundle create "$WORK/dbt-test.bundle" --all >/dev/null 2>&1 \
   && git bundle verify "$WORK/dbt-test.bundle" >/dev/null 2>&1; then
  note "dbt-test.bundle" "$(du -h "$WORK/dbt-test.bundle" | cut -f1) · verified"
else
  note "dbt-test.bundle" "*** FAILED ***"; fail=1
fi

cat > "$WORK/MANIFEST.txt" <<MAN
opsroom backup $STAMP
taken_at_utc: $STAMP
head_commit:  $(git rev-parse HEAD 2>/dev/null)
destination:  $DEST
encrypted:    gpg symmetric AES256 (dumps; bundle is plaintext source)
contents:
  identity-all.sql.gpg     pg_dumpall — asunset + keycloak + openfga
  product-opsroom.sql.gpg  product database
  opsroom-home.tar.gz.gpg  instance home volume
  dbt-test.bundle          git bundle --all
restore order: identity plane FIRST, product second, then doctor (report 91 §7)
decrypt: gpg --batch --decrypt --passphrase "\$OPSROOM_BACKUP_PASSPHRASE" -o out file.gpg
MAN

if [ "$fail" != "0" ]; then
  echo
  echo "✗ BACKUP INCOMPLETE — nothing uploaded. A partial backup restores to a"
  echo "  partial instance, so it is not stored at all rather than stored and trusted."
  exit 1
fi

echo "==> upload"
if [ "$MODE" = "s3" ]; then
  PREFIX="${DEST%/}/$STAMP"
  for f in "$WORK"/*; do
    aws s3 cp "$f" "$PREFIX/$(basename "$f")" --endpoint-url "$S3_ENDPOINT" >/dev/null 2>&1 \
      || { echo "    ✗ upload failed: $(basename "$f")"; fail=1; }
  done
  # VERIFY BY READING IT BACK from the destination — an upload that returned
  # success proves the call, not the object.
  n=$(aws s3 ls "$PREFIX/" --endpoint-url "$S3_ENDPOINT" 2>/dev/null | wc -l)
  note "objects at destination" "$n"
  [ "$n" -ge 5 ] || { echo "    ✗ expected 5 objects, found $n"; fail=1; }
  aws s3 cp "${DEST%/}/LATEST.txt" - --endpoint-url "$S3_ENDPOINT" >/dev/null 2>&1
  aws s3 cp "$WORK/MANIFEST.txt" "${DEST%/}/LATEST.txt" --endpoint-url "$S3_ENDPOINT" >/dev/null 2>&1
  # Write the marker INTO THE HOME VOLUME, not the repo: doctor runs in a
  # container that mounts the volume and never sees the host working tree.
  docker run --rm -v "$VOL":/home -v "$WORK":/w alpine \
    cp /w/MANIFEST.txt /home/.backup-latest >/dev/null 2>&1
  cp "$WORK/MANIFEST.txt" "$ROOT/.backup-latest" 2>/dev/null   # host-side convenience
else
  OUT="$LOCAL/opsroom-$STAMP"; mkdir -p "$OUT"; cp "$WORK"/* "$OUT/" || fail=1
  cp "$WORK/MANIFEST.txt" "$LOCAL/LATEST.txt"; cp "$WORK/MANIFEST.txt" "$ROOT/.backup-latest"
  docker run --rm -v "$VOL":/home -v "$WORK":/w alpine \
    cp /w/MANIFEST.txt /home/.backup-latest >/dev/null 2>&1
  note "written to" "$OUT"
fi

if [ "$MODE" = "s3" ] && [ "$fail" = "0" ] && [ "$RETAIN" -gt 0 ] 2>/dev/null; then
  echo "==> prune older than ${RETAIN}d"
  CUTOFF=$(date -u -d "-$RETAIN days" +%Y%m%d 2>/dev/null)
  if [ -n "$CUTOFF" ]; then
    aws s3 ls "${DEST%/}/" --endpoint-url "$S3_ENDPOINT" 2>/dev/null \
      | awk '{print $2}' | tr -d '/' | grep -E '^[0-9]{8}T' | while read -r d; do
        [ "${d%%T*}" -lt "$CUTOFF" ] 2>/dev/null && \
          aws s3 rm "${DEST%/}/$d/" --recursive --endpoint-url "$S3_ENDPOINT" >/dev/null 2>&1 \
          && echo "    pruned $d"
      done
  fi
fi

echo
if [ "$fail" = "0" ]; then
  echo "================ BACKUP COMPLETE ================"
  echo "$DEST/$STAMP"
  echo "Restoring has never been rehearsed until you rehearse it:"
  echo "  ./backup/restore-drill.sh $STAMP"
else
  echo "================ BACKUP FAILED AT UPLOAD ================"; exit 1
fi
