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
#   2. product plane — the opsroom database, AND the cluster's roles beside
#      it (2b). A `pg_dump` of one database carries every GRANT and no role.
#   3. instance home — the opsroom_home volume: the content tree. In neither
#      database. (`methodology/context.yaml` lived here until 2026-08-18;
#      `data/` is excluded ONLY when an object store holds it — see 5.)
#   4. the repo — `git bundle --all` of this checkout: the exact
#      orchestration commit your instance runs, so a restore rebuilds the
#      same stack rather than the newest one.
#   5. SOURCE BYTES — the data bucket mirrored into the backup bucket
#      (board 150 D3). After the object-store cutover uploaded files are NOT
#      in the home tarball, and a backup that lost them WOULD STILL REPORT
#      SUCCESS. That silence is why this is a numbered step with its own
#      assertion rather than a line in a runbook.
# Dumps are gpg-encrypted before they leave the machine. The repo bundle is
# not: it is public orchestration, and encrypting it would make the
# disaster-recovery path depend on the same secret twice. The mirrored source
# bytes are not either — see step 5 for why that asymmetry is deliberate.
#
# RESTORE ORDER (not the backup order): identity plane FIRST — Keycloak and
# OpenFGA must boot before anything validates — product second (roles before
# the dump), then the gate. `sudo bash install.sh --restore` does this for
# you; `./backup/restore-drill.sh` proves a backup can do it at all.

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

# THE PRECONDITION, with the product runner's severity (board 150 D9: the
# backup contract is this script's own precondition now that there is no
# doctor). This script used to print "Nothing to do." and exit 0 on an
# instance whose destination was `none` or unset — so a nightly timer
# reported success forever on an instance with no backups. A scheduled job
# that succeeds by doing nothing is the quietest way to have none. In
# production an unconfigured destination is a REFUSAL; anywhere else it is
# still "nothing to do", because a permanent red is a red people skip.
ENV_NAME="$(env_get OPSROOM_ENV)"
if [ -z "$DEST" ] || [ "$DEST" = "none" ]; then
  if [ "$ENV_NAME" = "production" ]; then
    echo "✗ OPSROOM_BACKUP_DEST is ${DEST:-unset} on a PRODUCTION instance — refusing."
    echo "  A production instance with no backup destination is an incomplete deployment,"
    echo "  the same class as a missing identity plane. Set OPSROOM_BACKUP_DEST (s3://…)"
    echo "  and OPSROOM_BACKUP_PASSPHRASE in .env, then re-run."
    exit 1
  fi
  [ -n "$DEST" ] || { echo "✗ no OPSROOM_BACKUP_DEST and no argument"; exit 1; }
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
OBJ_BASE="$(env_get OPSROOM_OBJECT_STORE_BASE)"
OBJ_ENDPOINT="$(env_get OPSROOM_OBJECT_STORE_ENDPOINT)"

fail=0
note() { printf '    %-32s %s\n' "$1" "$2"; }
enc() { # plaintext -> .gpg, then shred the plaintext
  gpg --batch --yes --symmetric --cipher-algo AES256 --pinentry-mode loopback \
      --passphrase "$PASSPHRASE" -o "$1.gpg" "$1" 2>/dev/null && rm -f "$1"; }

echo "==> backup $STAMP -> $DEST"

echo "==> 1/5  identity plane (all three databases)"
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

echo "==> 2/5  product plane"
if "${COMPOSE[@]}" exec -T opsroom-postgres pg_dump -U opsroom -d opsroom > "$WORK/product-opsroom.sql" 2>/dev/null \
   && [ -s "$WORK/product-opsroom.sql" ]; then
  enc "$WORK/product-opsroom.sql" && note "product-opsroom.sql.gpg" "$(du -h "$WORK/product-opsroom.sql.gpg" | cut -f1)"
else
  note "product-opsroom.sql" "*** FAILED ***"; fail=1
fi
# THE ROLES, BESIDE THE DUMP. `pg_dump` of ONE database carries every
# `GRANT … TO web_anon` and `OWNER TO opsroom` and never the roles
# themselves — so on a FRESH cluster the replay dies at the first GRANT with
# `role "web_anon" does not exist` (measured on the house instance,
# 2026-09-13, under ON_ERROR_STOP). With the roles pre-created the same dump
# restores clean. A backup that only restores onto a cluster which already
# has its roles is a backup for the one situation you will not be in.
# `--roles-only` is the whole cluster's roles: names, memberships and
# password HASHES — so it is encrypted like the dumps. `--restore` and the
# drill load it BEFORE the product replay and read the roles back.
if "${COMPOSE[@]}" exec -T opsroom-postgres pg_dumpall -U opsroom --roles-only > "$WORK/product-roles.sql" 2>/dev/null \
   && grep -qE 'CREATE ROLE (opsroom|web_anon)' "$WORK/product-roles.sql"; then
  nroles=$(grep -c 'CREATE ROLE' "$WORK/product-roles.sql")   # counted BEFORE enc shreds the plaintext
  enc "$WORK/product-roles.sql" && note "product-roles.sql.gpg" "$nroles roles (encrypted)"
else
  note "product-roles.sql" "*** FAILED — no CREATE ROLE opsroom/web_anon in the dump ***"; fail=1
fi

echo "==> 3/5  instance home volume"
VOL=$(docker volume ls --format '{{.Name}}' | grep -m1 'opsroom_home')
# `data/` IS EXCLUDED ONLY WHEN SOMETHING ELSE HOLDS IT. After the object-store
# cutover (D3) uploaded bytes live in the data bucket and step 5 mirrors them,
# so tarring them here would store the same bytes twice by two mechanisms with
# different lifetimes — and the copy inside a 30-day-pruned tarball would
# quietly become the stale one. BEFORE the cutover, `data/` in this volume is
# the ONLY copy, and excluding it unconditionally would drop every uploaded
# file from the backup while still reporting success. So the exclusion follows
# the configuration instead of the calendar. (The product repo's own runner
# excludes it unconditionally because the house instance has cut over; on the
# pull path both kinds of instance exist, and one of them is a customer.)
if [ -n "$OBJ_BASE" ]; then
  TAR_CMD="tar czf /out/opsroom-home.tar.gz --exclude=./data -C /src ."
  TAR_NOTE="data/ excluded — the object store holds it (step 5 mirrors it)"
else
  TAR_CMD="tar czf /out/opsroom-home.tar.gz -C /src ."
  TAR_NOTE="data/ INCLUDED — no object store configured, so this is its only copy"
fi
if [ -n "$VOL" ] && docker run --rm -v "$VOL":/src:ro -v "$WORK":/out alpine \
     sh -c "$TAR_CMD" 2>/dev/null && [ -s "$WORK/opsroom-home.tar.gz" ]; then
  note "  $TAR_NOTE" ""
  enc "$WORK/opsroom-home.tar.gz" && note "opsroom-home.tar.gz.gpg ($VOL)" "$(du -h "$WORK/opsroom-home.tar.gz.gpg" | cut -f1)"
else
  note "opsroom-home.tar.gz" "*** FAILED ***"; fail=1
fi

echo "==> 4/5  repo bundle (orchestration — deliberately NOT encrypted)"
if git bundle create "$WORK/dbt-test.bundle" --all >/dev/null 2>&1 \
   && git bundle verify "$WORK/dbt-test.bundle" >/dev/null 2>&1; then
  note "dbt-test.bundle" "$(du -h "$WORK/dbt-test.bundle" | cut -f1) · verified"
else
  note "dbt-test.bundle" "*** FAILED ***"; fail=1
fi

echo "==> 5/5  source bytes (the data bucket -> the backup bucket)"
# WHY THIS STEP EXISTS AT ALL (D3). Until the object-store cutover every
# uploaded byte was inside `opsroom-home.tar.gz`, because that tarball tars
# the whole home volume. The day uploads move to the object store that
# tarball stops containing them AND THE BACKUP KEEPS REPORTING SUCCESS —
# smaller, complete-looking, and missing every source file. A backup does not
# announce what it stopped covering, which is why the coverage is asserted
# here rather than assumed.
#
# NOT UNDER THE STAMP, AND THAT IS THE WHOLE LAYOUT DECISION. Retention below
# deletes stamped directories older than $RETAIN days, matching `^[0-9]{8}T`.
# Source data under a stamp would therefore be DELETED ON A TIMER — D3's
# lifecycle sentence inverted ("backups rotate and delete, data never"). It
# goes to `<bucket>/data/`, which that pattern cannot match, and the mirror is
# shared by every backup instead of copied per run.
#
# NO `--delete`, deliberately. A mirror that propagates deletions lets one
# `rm` in the data bucket erase the backup copy too, which is the thing a
# backup exists to survive. The mirror is additive; objects are content-
# addressed ({sha}.csv / {sha}.parquet), so an additive mirror never goes stale.
#
# NOT ENCRYPTED, unlike the dumps. These are the same bytes the running
# instance reads from the data bucket; encrypting each object would break the
# incremental sync (every run would re-upload everything) and would put the
# restore path behind the passphrase for data the instance itself holds in
# the clear. Stated because the asymmetry with the dumps is deliberate.
data_sync="not attempted"
if [ "$MODE" != "s3" ]; then
  if [ -n "$OBJ_BASE" ]; then
    data_sync="SKIPPED — file:// destination, object store IS configured"
    echo "    ⚠ $data_sync"
    echo "      This rehearsal does NOT exercise the source-bytes path."
    echo "      Use an s3:// destination to rehearse it."
  else
    data_sync="n/a — no object store configured"
    echo "    $data_sync"
  fi
elif [ -z "$OBJ_BASE" ]; then
  # THREE-VALUED: not configured is not the same fact as synced, and it must
  # not be reported in the same word.
  data_sync="n/a — OPSROOM_OBJECT_STORE_BASE is empty (no object store)"
  echo "    $data_sync"
elif [ -n "$OBJ_ENDPOINT" ] && [ "$OBJ_ENDPOINT" != "$S3_ENDPOINT" ]; then
  # ONE `aws s3 sync` SPEAKS TO ONE ENDPOINT. If the data bucket lives on a
  # different endpoint than the backup bucket, this call would resolve the
  # SOURCE bucket name against the BACKUP endpoint — finding nothing, or
  # worse, finding a same-named bucket that is not yours. Refuse and say so;
  # a cross-endpoint copy needs a download/upload path that does not exist
  # here yet and must not be faked.
  data_sync="*** REFUSED — data endpoint != backup endpoint ***"
  echo "    ✗ $data_sync"
  echo "      data:   $OBJ_ENDPOINT"
  echo "      backup: $S3_ENDPOINT"
  echo "      One 'aws s3 sync' speaks to one endpoint. Cross-endpoint copy is"
  echo "      not implemented — source bytes would silently not be backed up."
  fail=1
else
  DATA_DST="${DEST%/}/data"
  if aws s3 sync "$OBJ_BASE" "$DATA_DST" --endpoint-url "$S3_ENDPOINT" >/dev/null 2>&1; then
    # READ BACK AND COMPARE, because `sync` exits 0 when it copies nothing —
    # including when it copied nothing because it could not see the source.
    # THE LISTING'S EXIT STATUS, NOT JUST ITS LINE COUNT. `aws s3 ls` on a
    # bucket it cannot read exits nonzero and prints nothing, so `wc -l`
    # reports 0 — and `0 >= 0` is green. An empty data bucket (a fresh
    # instance, nothing uploaded yet) and an UNREADABLE one produce the
    # identical number, and only one of them means "nothing to back up".
    src_list=$(aws s3 ls "$OBJ_BASE/" --recursive --endpoint-url "$S3_ENDPOINT" 2>/dev/null); src_rc=$?
    src_n=$(printf '%s' "$src_list" | grep -c . )
    dst_n=$(aws s3 ls "$DATA_DST/" --recursive --endpoint-url "$S3_ENDPOINT" 2>/dev/null | grep -c . )
    if [ "$src_rc" != "0" ]; then
      data_sync="*** SOURCE UNREADABLE — cannot verify the mirror ***"
      echo "    ✗ $data_sync  ($OBJ_BASE)"
      echo "      The sync reported success; the source listing did not. Those"
      echo "      disagree, so the mirror is UNVERIFIED, which is not the same"
      echo "      fact as complete."
      fail=1
    elif [ "$dst_n" -ge "$src_n" ] 2>/dev/null; then
      # THE MIRROR'S TOTAL, NOT THIS RUN'S COPIES — and `dst >= src` rather
      # than `dst == src` on purpose. The sync never deletes, so an object
      # removed from the data bucket STAYS in the backup: that is the whole
      # reason `--delete` is omitted, and it makes dst > src the normal
      # healthy reading, not a discrepancy.
      data_sync="mirror holds $dst_n object(s) at $DATA_DST; data bucket has $src_n"
      note "source bytes" "$data_sync"
      [ "$dst_n" -gt "$src_n" ] 2>/dev/null && \
        note "" "($((dst_n - src_n)) retained here but no longer in the data bucket — the mirror does not delete)"
    else
      data_sync="*** INCOMPLETE — $dst_n mirrored of $src_n ***"
      echo "    ✗ $data_sync"; fail=1
    fi
  else
    data_sync="*** SYNC FAILED ***"
    echo "    ✗ $data_sync  ($OBJ_BASE -> ${DEST%/}/data)"
    echo "      The backup token needs READ on the data bucket (D3: the data"
    echo "      bucket has its own token — never the backup token's twin)."
    fail=1
  fi
fi

cat > "$WORK/MANIFEST.txt" <<MAN
opsroom backup $STAMP
taken_at_utc: $STAMP
head_commit:  $(git rev-parse HEAD 2>/dev/null)
product_tag:  $(grep -E '^OPSROOM_TAG=' release.env 2>/dev/null | cut -d= -f2-)
destination:  $DEST
encrypted:    gpg symmetric AES256 (dumps; bundle is plaintext orchestration)
contents:
  identity-all.sql.gpg     pg_dumpall — asunset + keycloak + openfga
  product-opsroom.sql.gpg  product database
  product-roles.sql.gpg    the product cluster's roles — load BEFORE the product replay
  opsroom-home.tar.gz.gpg  instance home volume ($TAR_NOTE)
  dbt-test.bundle          git bundle --all of the orchestration checkout
source bytes: $data_sync
  (mirrored at <bucket>/data/, OUTSIDE the stamp — retention never prunes it)
restore: sudo bash install.sh --restore   (identity plane FIRST, roles, product, then the gate)
rehearse: ./backup/restore-drill.sh $STAMP
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
  # THE ERROR IS THE EVIDENCE. Sending aws's stderr to /dev/null prints
  # "upload failed" N times and hides the one line that says why (a rotated
  # token reads as `Unauthorized`). The first failure's first line is kept,
  # with the key id masked if it ever appears; S3 errors do not carry the
  # secret.
  up_err=""
  for f in "$WORK"/*; do
    if ! out=$(aws s3 cp "$f" "$PREFIX/$(basename "$f")" --endpoint-url "$S3_ENDPOINT" 2>&1 >/dev/null); then
      echo "    ✗ upload failed: $(basename "$f")"; fail=1
      [ -n "$up_err" ] || up_err=$(printf '%s\n' "$out" | grep -v '^\s*$' | head -1 | sed "s/${AWS_ACCESS_KEY_ID:-__none__}/<key id>/g" | cut -c1-160)
    fi
  done
  [ -z "$up_err" ] || echo "      first error: $up_err"
  # VERIFY BY READING IT BACK from the destination — an upload that returned
  # success proves the call, not the object. SIX objects since the roles file
  # joined them (five before deploy-v0.2.2).
  n=$(aws s3 ls "$PREFIX/" --endpoint-url "$S3_ENDPOINT" 2>/dev/null | wc -l)
  note "objects at destination" "$n"
  [ "$n" -ge 6 ] || { echo "    ✗ expected 6 objects, found $n"; fail=1; }
  aws s3 cp "${DEST%/}/LATEST.txt" - --endpoint-url "$S3_ENDPOINT" >/dev/null 2>&1
  aws s3 cp "$WORK/MANIFEST.txt" "${DEST%/}/LATEST.txt" --endpoint-url "$S3_ENDPOINT" >/dev/null 2>&1
  # Write the marker INTO THE HOME VOLUME as well as the host: anything that
  # reads it from inside a container mounts the volume and never sees the
  # host working tree.
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
