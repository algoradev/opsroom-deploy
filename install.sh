#!/usr/bin/env bash
# OpsRoom installer — from a bare Ubuntu box to a welcome screen.
#
#   curl -fsSL <hosted-url>/install.sh | sudo bash
#   sudo bash install.sh
#   sudo OPSROOM_PULL_TOKEN=... TS_AUTHKEY=tskey-auth-... bash install.sh   # unattended
#   sudo bash install.sh --token-file /path/to/token                        # token w/o env or tty
#
# It asks for ONE thing — a Tailscale auth key — joins the tailnet, and
# prints a URL. THEN IT EXITS (~2 minutes). The rest happens in your
# browser: the form takes the registry pull token (validated live at
# submit) and everything else; the product download (NOTHING is built on
# this box) runs as the install's first progress step. A dropped SSH
# connection cannot kill the install — it does not run in your session.
# Unattended: provide OPSROOM_PULL_TOKEN (or --token-file) and the pull
# happens up front, the form field disappears.
#
# Other modes:
#   sudo bash install.sh --upgrade    # git pull + pull + up, gated by upgrades.json
#   sudo bash install.sh --restore    # rebuild an instance from its backup (same browser flow)
#   sudo bash install.sh --fresh      # wipe THIS project (containers+volumes+config) for a clean re-run
#
# The product arrives as pulled, signed images pinned by release.env.
# This repo is public and contains no secrets — every credential is
# generated on your box or typed into the form by you.

set -euo pipefail

REPO_HTTPS="${OPSROOM_DEPLOY_REPO:-https://github.com/algoradev/opsroom-deploy.git}"
REGISTRY_HOST="ghcr.io"          # must match release.env's OPSROOM_REGISTRY host
REGISTRY_NS="algoradev"
OPS_USER="${OPSROOM_USER:-opsroom}"
SETUP_PORT="${OPSROOM_SETUP_PORT:-8100}"
STATUS_FILE="/run/opsroom-setup.status"
INSTALL_LOG="/var/log/opsroom-install.log"
SETUP_DIR="/opt/opsroom-setup"
TS_HOSTNAME="${OPSROOM_TS_HOSTNAME:-opsroom}"

say()  { printf '\033[1;35m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root: sudo bash install.sh"
[ -r /etc/os-release ] || die "cannot read /etc/os-release"
. /etc/os-release
case "${ID:-}" in ubuntu|debian) ;; *) die "Ubuntu/Debian only (found ${ID:-unknown})";; esac
export DEBIAN_FRONTEND=noninteractive

note() { printf '%s\n' "$1" > "$STATUS_FILE"; }

# ════════════════════════════════════════════════════════════════════════
# THE GATE — board 150 D9: there is no doctor. The checks live where the
# failures happen (compose healthchecks, the api's own /healthz, the realm
# script); this READS them, in that order, and answers yes or no. Used by
# --deploy (final checks) and --upgrade (before the version is recorded).
# Needs the caller's run() and $DC. Details go to $INSTALL_LOG.
# ════════════════════════════════════════════════════════════════════════
gate() {
  local bad hz rc=0
  # 1. every service that declares a healthcheck reports healthy
  bad=$(run $DC ps --format '{{.Service}} {{.Health}}' 2>>"$INSTALL_LOG" | awk '$2 != "" && $2 != "healthy"') || true
  if [ -n "$bad" ]; then printf 'gate: unhealthy services:\n%s\n' "$bad" >>"$INSTALL_LOG"; return 1; fi
  # 2. the api's /healthz — its own dependencies as facts, 503 when a
  #    configured one fails. Absent (404) on 0.1.1 images: the compose
  #    healthcheck stands alone there, and that is recorded, not hidden.
  hz=$(run $DC exec -T opsroom-api python -c '
import sys, urllib.request as u, urllib.error as e
try:
    print(u.urlopen("http://127.0.0.1:8001/healthz", timeout=5).read().decode()[:600])
except e.HTTPError as x:
    print(x.read().decode()[:600]); sys.exit(3 if x.code == 404 else 1)
' 2>>"$INSTALL_LOG") || rc=$?
  case $rc in
    0) printf 'gate: healthz ok: %s\n' "$hz" >>"$INSTALL_LOG" ;;
    3) printf 'gate: healthz absent on this image (pre-0.2.0) — compose health stands alone\n' >>"$INSTALL_LOG" ;;
    *) printf 'gate: healthz FAILED (%s): %s\n' "$rc" "$hz" >>"$INSTALL_LOG"; return 1 ;;
  esac
  # 3. the realm is coherent (and its session lifespans survived the up)
  run ./bin/realm-doctor.sh >>"$INSTALL_LOG" 2>&1 || { printf 'gate: realm-doctor FAILED\n' >>"$INSTALL_LOG"; return 1; }
  return 0
}

# ════════════════════════════════════════════════════════════════════════
# CONFIG PRE-CHECK — the manifest, asked THROUGH THE IMAGE (153 item 3).
# The customer host has no checkout and no venv, so the image is the only
# thing that carries the manifest; `--process` asks only the rows the
# container can answer, because the backup token and passphrase are the
# HOST's and are absent inside the API by design (D3). Without this the
# first sign of a gap is the API refusing to boot.
#
# THREE ANSWERS, NOT TWO. An image that predates the manifest cannot be
# asked, and that is reported as "cannot pre-check" — never as a pass,
# which is the wording up.sh uses for the same situation.
# ════════════════════════════════════════════════════════════════════════
config_precheck() {
  local out rc=0
  out=$(run $DC run --rm --no-deps opsroom-api python -m opsroom.config check --process 2>&1) || rc=$?
  printf 'config check --process (rc=%s):\n%s\n' "$rc" "$out" >>"$INSTALL_LOG"
  case "$out" in
    *"CONFIG REFUSED"*|*"CONFIG INCOMPLETE"*)
      CONFIG_GAPS=$(printf '%s\n' "$out" | grep '^✗' | head -3 | tr '\n' ' ')
      return 1 ;;
    *"every gated feature is set"*) return 0 ;;
    *) printf 'config check: this image carries no config manifest — cannot pre-check, NOT a pass\n' >>"$INSTALL_LOG"
       return 0 ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════
# HANDOVER — the browser is watching one URL; at this moment it must stop
# being the setup server and start being the product. ORDER MATTERS
# (measured, twice): kill the setup server by ITS OWN pid, reset serve, then
# point :443 at the product. Shared by the install and the restore, because
# a second copy of this is a second place for the order to rot.
# ════════════════════════════════════════════════════════════════════════
handover() {
  if [ -r "$SETUP_DIR/server.pid" ]; then kill "$(cat "$SETUP_DIR/server.pid")" 2>/dev/null || true; fi
  pkill -f "$SETUP_DIR/server.py" 2>/dev/null || true
  sleep 1
  tailscale serve reset >/dev/null 2>&1 || true
  tailscale serve --bg --https=443 localhost:5173 >/dev/null 2>&1 || true
}

# ════════════════════════════════════════════════════════════════════════
# THE BOOT TRIO — product config, board 150 D9: a production image past
# b88df95 REFUSES to start unless SESSION_TOKEN_PRIVATE_KEY_B64, MCP_BEARER
# and OPSROOM_BACKUP_DEST are each set. Only OPSROOM_BACKUP_DEST may be
# declared off with `none`; the bearer REFUSES that word in every
# environment (D13) and the signing key has no meaningful off state. A fresh .env
# gets all three at generation; an OLDER .env (installed before this) gets
# the two mintable ones appended here, once, before an upgrade can pull an
# image that would refuse it. The backup destination is never guessed.
# ════════════════════════════════════════════════════════════════════════
mint_session_key() {
  # RSA-2048 PEM, base64 on ONE line (what asunset_core's signer loads).
  # Minted once per instance: a new key logs every agent session out.
  local k; k=$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null | base64 -w0) || true
  [ "${#k}" -gt 1500 ] || return 1
  printf '%s' "$k"
}
ensure_trio() {   # $1 = path to .env ; returns 1 with a message when a human must decide
  local envf="$1" k
  if ! grep -q '^SESSION_TOKEN_PRIVATE_KEY_B64=.' "$envf"; then
    k=$(mint_session_key) || { echo "could not mint the session signing key (openssl genpkey)"; return 1; }
    printf 'SESSION_TOKEN_PRIVATE_KEY_B64=%s\n' "$k" >> "$envf"; echo "SESSION_TOKEN_PRIVATE_KEY_B64: minted and appended to $envf"
  fi
  # MCP_BEARER HAS NO OFF-SWITCH, AND `none` IS REFUSED BY NAME (D13). The
  # MCP server reads this variable AS the shared secret, so `MCP_BEARER=none`
  # does not turn admission off — it installs a live door key whose value is
  # the word "none", admits anything presenting it, and carries no identity.
  # An earlier version of this file told operators `none` was a valid choice
  # for all three boot values; it is not, and a hand-edited .env that took
  # that advice is caught here rather than at a boot refusal that only says
  # the value was refused.
  case "$(grep '^MCP_BEARER=' "$envf" | head -1 | cut -d= -f2-)" in
    none|log)
      echo "MCP_BEARER is set to a word the MCP server would use AS THE SECRET — 'none' does not disable authentication, it installs a door key whose value is that word. Remove the line (this installer will mint a real secret) or set one yourself."
      return 1 ;;
  esac
  if ! grep -q '^MCP_BEARER=.' "$envf"; then
    printf 'MCP_BEARER=%s\n' "$(openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-48)" >> "$envf"; echo "MCP_BEARER: minted and appended to $envf"
  fi
  if ! grep -q '^OPSROOM_BACKUP_DEST=.' "$envf"; then
    echo "OPSROOM_BACKUP_DEST is unset in $envf — the product refuses to boot without a decision. Set it to s3://<bucket> (plus the OPSROOM_BACKUP_S3_* lines, see .env.example) or, deliberately, to: none"
    return 1
  fi
  return 0
}

# ════════════════════════════════════════════════════════════════════════
# DEPLOY PHASE — invoked by the setup server AFTER the form is submitted,
# detached from any terminal, writing a one-line status the browser polls.
#   install.sh --deploy <repo_dir> <answers.json> <ts_dns> <ops_user>
# The sequence below is not designed — it is TRANSCRIBED from the slice-1
# boot proof that ran it (product repo, reports/142 OUTCOME).
# ════════════════════════════════════════════════════════════════════════
if [ "${1:-}" = "--deploy" ]; then
  REPO_DIR="$2"; ANSWERS="$3"; TS_DNS="$4"; OPS_USER="${5:-opsroom}"; DEPLOY_MODE="${6:-install}"
  HOME_DIR=$(getent passwd "$OPS_USER" | cut -d: -f6)
  cd "$REPO_DIR"
  dfail() { note "error:$1"; exit 1; }
  # NEVER die silently: set -e exits with NO message; the trap turns any
  # unhandled failure into a recorded error the browser shows.
  trap 'note "error:step failed at line $LINENO: ${BASH_COMMAND}"; exit 1' ERR
  j() { python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],''))" "$ANSWERS" "$1"; }
  run() { sudo -u "$OPS_USER" env PATH="/usr/local/bin:$PATH" HOME="$HOME_DIR" "$@"; }
  # release.env (tracked pin) first, .env (yours) second — later wins.
  DC="docker compose --env-file release.env --env-file .env"
  rnd() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-32; }

  # ══════════════════════════════════════════════════════════════════════
  # RESTORE — rebuild an instance from its backup onto this machine.
  #
  # THE ORDER IS THE WHOLE DESIGN, and each step is placed where it is
  # because of something that breaks otherwise:
  #   configuration FIRST, because the databases only accept the passwords
  #     that created them (a freshly generated .env cannot start the stack
  #     it just restored);
  #   the host URLs rewritten, because the backup names a machine that is
  #     gone and the API validates tokens against an issuer the browser
  #     must also see;
  #   the image tag pinned to what the backup was taken with, because the
  #     dumps carry that version's schema;
  #   DATABASES ONLY up before the replay, because Keycloak and OpenFGA
  #     initialise their own schemas the moment they boot;
  #   read the restored rows back BEFORE handing over, because a restore
  #     that reports success over an empty realm is the failure this whole
  #     path exists to prevent.
  # ══════════════════════════════════════════════════════════════════════
  if [ "$DEPLOY_MODE" = restore ]; then
    note "restoring:reading the backup"
    BUCKET=$(j backup_bucket); S3EP=$(j s3_endpoint)
    PASSPHRASE=$(j backup_pass); AGEKEY=$(j age_key); STAMP=$(j stamp)
    PULL_TOKEN=$(j pull_token)
    export AWS_ACCESS_KEY_ID="$(j s3_key)" AWS_SECRET_ACCESS_KEY="$(j s3_secret)"
    export AWS_DEFAULT_REGION=auto
    DEST="s3://$BUCKET"

    # The age key lands first: it is the one input nothing else substitutes.
    AGE_DIR="$HOME_DIR/.config/sops/age"; mkdir -p "$AGE_DIR"
    ( umask 077; printf '%s\n' "$AGEKEY" > "$AGE_DIR/keys.txt" )
    chown -R "$OPS_USER:$OPS_USER" "$HOME_DIR/.config"
    shred -u "$ANSWERS" 2>/dev/null || rm -f "$ANSWERS"

    if [ -z "$STAMP" ]; then
      STAMP=$(aws s3 ls "${DEST%/}/" --endpoint-url "$S3EP" 2>/dev/null \
              | awk '{print $2}' | tr -d '/' | grep -E '^[0-9]{8}T' | sort | tail -1)
      [ -n "$STAMP" ] || dfail "no backups found at $DEST — check the bucket name, the endpoint and the keys"
    fi
    note "restoring:reading $STAMP"

    # DOWNLOAD EVERYTHING FIRST. A restore that fails partway through its
    # downloads has already begun replacing a database with nothing to
    # finish the job.
    W="$REPO_DIR/.restore-work.$$"; mkdir -p "$W"; chmod 700 "$W"
    for f in env.age MANIFEST.txt identity-all.sql.gpg product-opsroom.sql.gpg \
             product-roles.sql.gpg opsroom-home.tar.gz.gpg; do
      aws s3 cp "${DEST%/}/$STAMP/$f" "$W/$f" --endpoint-url "$S3EP" >/dev/null 2>&1 || true
    done
    [ -s "$W/identity-all.sql.gpg" ] || dfail "$STAMP carries no identity dump — that is not a complete backup"
    [ -s "$W/product-opsroom.sql.gpg" ] || dfail "$STAMP carries no product dump — that is not a complete backup"
    [ -s "$W/env.age" ] || dfail "$STAMP carries no sealed configuration (env.age), so its databases cannot be reached: a dump re-creates the roles with their ORIGINAL passwords and the realm keeps its original client secret, neither of which a new install can guess. Take a fresh backup while the old instance still runs, or restore this one by hand with its original .env."

    note "restoring:recovering the configuration"
    age -d -i "$AGE_DIR/keys.txt" "$W/env.age" > "$REPO_DIR/.env" 2>/dev/null \
      || dfail "the age key did not open this backup's configuration — wrong key, or it was rotated after $STAMP was taken"
    grep -q '^APP_DB_PASSWORD=.' "$REPO_DIR/.env" \
      || dfail "what the age key opened is not an OpsRoom configuration"
    chown "$OPS_USER:$OPS_USER" "$REPO_DIR/.env"; chmod 600 "$REPO_DIR/.env"

    # THE HOST MOVED. Every URL naming the old box must name this one, or the
    # API validates tokens against an issuer the browser never sees — the 401
    # found live on the first pull-path login, 2026-08-30.
    python3 - "$REPO_DIR/.env" "$TS_DNS" <<'PYEOF' || dfail "could not rewrite the host URLs in the recovered configuration"
import sys
path, dns = sys.argv[1], sys.argv[2]
new = {"TAILSCALE_HOST": dns,
       "OPSROOM_PUBLIC_ORIGIN": "https://" + dns,
       "OPSROOM_PUBLIC_URL": "https://" + dns,
       "KEYCLOAK_PUBLIC_URL": "https://" + dns + "/auth"}
out, seen = [], set()
for line in open(path):
    key = line.split("=", 1)[0].strip()
    if key in new:
        out.append("%s=%s\n" % (key, new[key])); seen.add(key)
    else:
        out.append(line)
for key, value in new.items():
    if key not in seen:
        out.append("%s=%s\n" % (key, value))
open(path, "w").writelines(out)
PYEOF

    # PIN THE TAG THE BACKUP WAS TAKEN WITH. The dumps carry that version's
    # schema; starting newer code over them asks it to read a database its
    # migrations have not reached. A restore REPRODUCES the instance;
    # `--upgrade` is what moves it forward, and it warns about this pin.
    RTAG=$(grep -E '^product_tag:' "$W/MANIFEST.txt" 2>/dev/null | awk '{print $2}')
    if [ -n "$RTAG" ]; then
      if grep -q '^OPSROOM_TAG=' "$REPO_DIR/.env"; then
        sed -i "s|^OPSROOM_TAG=.*|OPSROOM_TAG=$RTAG|" "$REPO_DIR/.env"
      else
        printf 'OPSROOM_TAG=%s\n' "$RTAG" >> "$REPO_DIR/.env"
      fi
    else
      RTAG=$(grep '^OPSROOM_TAG=' "$REPO_DIR/release.env" | cut -d= -f2)
      printf 'restore: the backup names no product version; using the current release (%s)\n' "$RTAG" >>"$INSTALL_LOG"
    fi
    ensure_trio "$REPO_DIR/.env" >>"$INSTALL_LOG" 2>&1 \
      || dfail "the recovered configuration is missing boot values — see $INSTALL_LOG"
    SU=$(grep '^POSTGRES_SUPERUSER=' "$REPO_DIR/.env" | cut -d= -f2)
    [ -n "$SU" ] || dfail "the recovered configuration names no POSTGRES_SUPERUSER"

    note "restoring:downloading the product (several GB — the longest step)"
    printf '%s' "$PULL_TOKEN" | run docker login "$REGISTRY_HOST" -u "${OPSROOM_PULL_USER:-$REGISTRY_NS}" --password-stdin >/dev/null 2>&1 \
      || dfail "docker login failed with the form's token"
    run $DC pull -q >>"$INSTALL_LOG" 2>&1 || dfail "image pull failed — see $INSTALL_LOG"

    note "restoring:starting the databases (and nothing else yet)"
    run $DC up -d --wait --wait-timeout 600 postgres opsroom-postgres >>"$INSTALL_LOG" 2>&1 \
      || dfail "the database containers did not come up — see $INSTALL_LOG"

    note "restoring:decrypting"
    for f in identity-all.sql product-opsroom.sql product-roles.sql opsroom-home.tar.gz; do
      [ -s "$W/$f.gpg" ] || continue
      gpg --batch --yes --quiet --pinentry-mode loopback --passphrase "$PASSPHRASE" \
          -o "$W/$f" --decrypt "$W/$f.gpg" 2>/dev/null \
        || dfail "$f did not decrypt — the backup passphrase does not match $STAMP"
    done

    note "restoring:the identity plane (realm, grants, organizations)"
    # NOISY BY NATURE and judged by CONTENT, exactly as the drill judges it:
    # the databases and roles already exist (the postgres init created them
    # from the recovered configuration), so the dump's CREATE statements warn.
    run $DC exec -T postgres psql -U "$SU" -d postgres -q < "$W/identity-all.sql" >>"$INSTALL_LOG" 2>&1 || true

    note "restoring:the product plane (roles first, then the rows)"
    if [ -s "$W/product-roles.sql" ]; then
      run $DC exec -T opsroom-postgres psql -U opsroom -d postgres -q < "$W/product-roles.sql" >>"$INSTALL_LOG" 2>&1 || true
    fi
    run $DC exec -T opsroom-postgres psql -U opsroom -d opsroom -q -v ON_ERROR_STOP=1 < "$W/product-opsroom.sql" >>"$INSTALL_LOG" 2>&1 \
      || dfail "the product database did not replay — see $INSTALL_LOG. The rows you cannot rebuild are in that dump, so nothing is handed over."

    note "restoring:reading the restored data back"
    pq() { run $DC exec -T "$1" psql -U "$2" -d "$3" -tAc "$4" 2>/dev/null | tr -d '[:space:]'; }
    KU=$(pq postgres "$SU" keycloak "SELECT count(*) FROM user_entity")
    OT=$(pq postgres "$SU" openfga "SELECT count(*) FROM tuple")
    AO=$(pq postgres "$SU" asunset "SELECT count(*) FROM organization")
    PV=$(pq opsroom-postgres opsroom opsroom "SELECT version_num FROM alembic_version")
    PS=$(pq opsroom-postgres opsroom opsroom "SELECT count(*) FROM registry.sources")
    printf 'restore read-back: keycloak_users=%s openfga_tuples=%s orgs=%s product_schema=%s sources=%s\n' \
      "${KU:-0}" "${OT:-0}" "${AO:-0}" "${PV:-none}" "${PS:-?}" >>"$INSTALL_LOG"
    [ "${KU:-0}" -gt 0 ] 2>/dev/null || dfail "the restored realm has no users — the identity replay did not land (see $INSTALL_LOG)"
    [ "${OT:-0}" -gt 0 ] 2>/dev/null || dfail "the restored authorization store has no grants — every permission would be gone"
    [ "${AO:-0}" -gt 0 ] 2>/dev/null || dfail "the restored identity database has no organizations"
    [ -n "$PV" ] || dfail "the restored product database reports no schema revision"

    note "restoring:the instance home"
    if [ -s "$W/opsroom-home.tar.gz" ]; then
      # Let COMPOSE create the volume (it labels what it owns; a volume made
      # by hand is one compose refuses to adopt), then fill it.
      run $DC run --rm --no-deps --entrypoint /bin/true opsroom-api >>"$INSTALL_LOG" 2>&1 || true
      VOL=$(docker volume ls --format '{{.Name}}' | grep -m1 'opsroom_home')
      [ -n "$VOL" ] || dfail "the instance home volume was not created — see $INSTALL_LOG"
      docker run --rm -v "$VOL":/dst -v "$W":/in alpine tar xzf /in/opsroom-home.tar.gz -C /dst >>"$INSTALL_LOG" 2>&1 \
        || dfail "the home archive did not extract into $VOL"
    fi

    note "restoring:checking the recovered configuration"
    config_precheck || dfail "the recovered configuration is incomplete: ${CONFIG_GAPS:-see $INSTALL_LOG}"

    note "restoring:starting the product"
    # keycloak-init runs here and is SAFE against a restored realm: Keycloak's
    # own --import-realm ignores a realm that exists, and init.sh only pushes
    # policy knobs from the recovered configuration — the same values that
    # built this realm. It does reset session lifespans, the known
    # regression, so they are re-applied after, as on an install.
    if ! run $DC up -d --wait --wait-timeout 900 >>"$INSTALL_LOG" 2>&1; then
      run $DC logs --tail 40 opsroom-api >>"$INSTALL_LOG" 2>&1 || true
      dfail "the stack did not come up healthy — see $INSTALL_LOG"
    fi
    note "restoring:re-applying realm session settings"
    run ./bin/kc-session-lifespans.sh >/dev/null 2>&1 || true
    # NO opsroom-init: the organization, team and project came back with the
    # data. Running it would create a second one beside the restored rows.

    note "restoring:final checks"
    gate || dfail "final checks failed (compose health / api healthz / realm) — see $INSTALL_LOG"

    # The source bytes are NOT copied back. They live in the data bucket,
    # which outlived the machine; the mirror at <bucket>/data/ is the spare
    # for the day the bucket itself is lost, and copying it over a live
    # bucket would be the wrong default.
    printf 'restore: source bytes untouched — the data bucket is independent of this host.\n' >>"$INSTALL_LOG"
    printf '  If the DATA bucket was lost too: aws s3 sync %s/data/ <new-data-bucket>/\n' "${DEST%/}" >>"$INSTALL_LOG"

    rm -rf "$W"
    mkdir -p /etc/opsroom
    { printf 'OPSROOM_TAG=%s\n' "$RTAG"
      printf 'DEPLOY_COMMIT=%s\n' "$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
      printf 'RESTORED_FROM=%s\n' "$STAMP"; } > /etc/opsroom/versions

    note "done:https://${TS_DNS}/"
    sleep 5
    handover
    exit 0
  fi

  note "installing:writing configuration"
  ADMIN_USER=$(j admin_user); ADMIN_PASS=$(j admin_pass)
  DISTRO=$(j distro)
  SESSION_KEY_B64=$(mint_session_key) || dfail "could not mint the session signing key (openssl genpkey)"
  # Idempotency (contract 141 §5): check-then-act against BOTH .env and
  # volume state. A half-done box resumes or refuses loudly — never
  # regenerates secrets over an initialized database.
  if [ -f .env ] && docker volume inspect opsroom_postgres-data >/dev/null 2>&1; then
    note "installing:resuming with the existing configuration"
    ensure_trio .env >>"$INSTALL_LOG" 2>&1 || dfail "the existing .env is missing boot configuration — see $INSTALL_LOG"
  elif [ -f .env ]; then
    dfail ".env exists but the database volumes do not — unknown half-state. Run: sudo bash install.sh --fresh"
  else
    {
      printf '# generated by install.sh %s — do not commit\n' "$(date -u +%FT%TZ)"
      printf 'TAILSCALE_HOST=%s\n' "$TS_DNS"
      printf 'OPSROOM_PUBLIC_ORIGIN=https://%s\nOPSROOM_PUBLIC_URL=https://%s\n' "$TS_DNS" "$TS_DNS"
      # The issuer the API validates tokens against MUST match what the
      # browser sees (compose: KEYCLOAK_ISSUER=$KEYCLOAK_PUBLIC_URL/realms/…).
      # Left unset, every API request 401s with "issuer mismatch" — found
      # live on the first customer-path login, 2026-08-30.
      printf 'KEYCLOAK_PUBLIC_URL=https://%s/auth\n' "$TS_DNS"
      printf 'POSTGRES_SUPERUSER=postgres\nPOSTGRES_SUPERUSER_PASSWORD=%s\n' "$(rnd)"
      printf 'APP_DB_NAME=asunset\nAPP_DB_OWNER=asunset_owner\nAPP_DB_OWNER_PASSWORD=%s\n' "$(rnd)"
      printf 'APP_DB_USER=asunset\nAPP_DB_PASSWORD=%s\n' "$(rnd)"
      printf 'KC_DB_NAME=keycloak\nKC_DB_USER=keycloak\nKC_DB_PASSWORD=%s\n' "$(rnd)"
      printf 'FGA_DB_NAME=openfga\nFGA_DB_USER=openfga\nFGA_DB_PASSWORD=%s\n' "$(rnd)"
      printf 'KEYCLOAK_REALM=asunset\nKEYCLOAK_ADMIN=admin\nKEYCLOAK_ADMIN_PASSWORD=%s\n' "$(rnd)"
      printf 'KEYCLOAK_API_CLIENT_SECRET=%s\nOPENFGA_API_KEY=%s\n' "$(rnd)" "$(rnd)"
      printf 'KEYCLOAK_EXTRA_AUDIENCES=opsroom-api,opsroom-mcp,orchestration\n'
      printf 'OPSROOM_PG_PASSWORD=%s\n' "$(rnd)"
      # Enforced from FIRST boot — the api's lifespan bootstraps the
      # authorization store only when enforcing (boot-proof lesson).
      printf 'OPSROOM_ENV=production\nOPSROOM_AUTH_ENFORCE=true\n'
      printf 'INVITE_DELIVERY=%s\nMCP_BEARER=%s\n' "$(j invite_mode)" "$(openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-48)"
      # Boot trio member 1 of 3 (MCP_BEARER above, OPSROOM_BACKUP_DEST below).
      printf 'SESSION_TOKEN_PRIVATE_KEY_B64=%s\n' "$SESSION_KEY_B64"
      # D1 (board 150): the distro is instance identity, pinned at install
      # like the image tag. `none` = a blank instance, and no line is written.
      case "$DISTRO" in ""|none) ;; *) printf 'OPSROOM_DISTRO=%s\n' "$DISTRO" ;; esac
      printf 'OPSROOM_BACKUP_DEST=s3://%s\nOPSROOM_BACKUP_S3_ENDPOINT=%s\n' "$(j backup_bucket)" "$(j s3_endpoint)"
      # FILE STORAGE — the SECOND bucket, its own token (board 150 D3/D7).
      # After G5 the API refuses to boot in production without these: an
      # instance that cannot store a file cannot take an upload, and D4 left
      # no path-shaped fallback to pretend with.
      printf 'OPSROOM_OBJECT_STORE_BASE=%s\nOPSROOM_OBJECT_STORE_ENDPOINT=%s\n' "$(j obj_base)" "$(j obj_endpoint)"
      printf 'OPSROOM_OBJECT_STORE_ACCESS_KEY_ID=%s\nOPSROOM_OBJECT_STORE_SECRET_ACCESS_KEY=%s\n' "$(j obj_key)" "$(j obj_secret)"
      printf 'OPSROOM_OBJECT_STORE_REGION=%s\n' "$(j obj_region)"
      printf 'OPSROOM_BACKUP_S3_ACCESS_KEY_ID=%s\nOPSROOM_BACKUP_S3_SECRET_ACCESS_KEY=%s\n' "$(j s3_key)" "$(j s3_secret)"
      printf 'OPSROOM_BACKUP_PASSPHRASE=%s\nOPSROOM_BACKUP_RETAIN_DAYS=30\n' "$(j backup_pass)"
      printf 'OPSROOM_ORG=instance\nOPSROOM_TEAM=default\nOPSROOM_PROJECT=default\n'
      printf 'VECTOR_LOG_LEVEL=info\n'
    } > .env
    chown "$OPS_USER:$OPS_USER" .env; chmod 600 .env
  fi

  AGE_DIR="$HOME_DIR/.config/sops/age"; mkdir -p "$AGE_DIR"
  if [ "$(j age_mode)" = restore ]; then
    ( umask 077; j age_key > "$AGE_DIR/keys.txt" )
  elif [ -f "$AGE_DIR/keys.txt" ]; then
    # NEVER destroy an existing key on generate-mode: if it encrypted any
    # backup, deleting it is the disaster this project already lived once.
    dfail "an age key already exists on this box but the form chose Generate. Choose Restore, or wipe deliberately: sudo bash install.sh --fresh"
  else
    ( umask 077; age-keygen -o "$AGE_DIR/keys.txt" 2>/dev/null )
  fi
  chown -R "$OPS_USER:$OPS_USER" "$HOME_DIR/.config"
  PULL_TOKEN=$(j pull_token)
  shred -u "$ANSWERS" 2>/dev/null || rm -f "$ANSWERS"

  # deploy-v0.2.0: the pull runs HERE, as the install's first visible
  # step, with the token from the form (already registry-validated at
  # submit). Absent token = the unattended path already pulled up front.
  if [ -n "$PULL_TOKEN" ]; then
    note "installing:downloading the product (several GB — the longest step)"
    printf '%s' "$PULL_TOKEN" | run docker login "$REGISTRY_HOST" -u "${OPSROOM_PULL_USER:-$REGISTRY_NS}" --password-stdin >/dev/null 2>&1 \
      || dfail "docker login failed with the form's token"
    run $DC pull -q >>"$INSTALL_LOG" 2>&1 || dfail "image pull failed — see $INSTALL_LOG"
  fi

  note "installing:starting the identity plane"
  run $DC up -d --wait --wait-timeout 900 postgres openfga keycloak vector >/dev/null 2>&1 || dfail "identity plane did not come up"
  note "installing:seeding keycloak"
  run $DC up -d --wait --wait-timeout 600 keycloak-init >/dev/null 2>&1 || true
  # keycloak-init is a one-shot: --wait cannot express "ran to completion",
  # so poll for exited. BOUNDED, and the exit code is read: an unbounded
  # loop is a browser parked on this step forever with nothing to show (the
  # ERR trap never fires for a loop that simply never ends), and a
  # keycloak-init that exited NON-ZERO used to sail on and fail later,
  # somewhere less informative.
  KCI_DEADLINE=$((SECONDS + 900))
  while :; do
    KCI_ID=$(run $DC ps -aq keycloak-init 2>/dev/null | head -1 || true)
    if [ -n "$KCI_ID" ] && [ "$(docker inspect "$KCI_ID" --format '{{.State.Status}}' 2>/dev/null || true)" = exited ]; then
      KCI_RC=$(docker inspect "$KCI_ID" --format '{{.State.ExitCode}}' 2>/dev/null || echo 1)
      [ "$KCI_RC" = 0 ] || dfail "keycloak seeding failed (keycloak-init exited $KCI_RC) — see $INSTALL_LOG"
      break
    fi
    [ "$SECONDS" -lt "$KCI_DEADLINE" ] || dfail "keycloak seeding did not finish within 15 minutes — see $INSTALL_LOG"
    sleep 2
  done

  note "installing:configuring the realm"
  run ./bin/kc-session-lifespans.sh >/dev/null 2>&1 || true
  KA=$(grep '^KEYCLOAK_ADMIN=' .env | cut -d= -f2); KP=$(grep '^KEYCLOAK_ADMIN_PASSWORD=' .env | cut -d= -f2)
  kc() { docker exec -i "$(run $DC ps -q keycloak)" /opt/keycloak/bin/kcadm.sh "$@" 2>/dev/null; }
  kc config credentials --server http://localhost:8080/auth --realm master --user "$KA" --password "$KP"
  W=$(kc get clients -r asunset -q clientId=asunset-web --fields id --format csv --noquotes | tr -d '\r\n"')
  kc update "clients/$W" -r asunset -s 'attributes."oauth2.device.authorization.grant.enabled"=true'
  # The admin YOU chose, as platform_admin — no seeded users exist in this
  # realm export (they were stripped; the audit found them shipping with
  # working passwords).
  kc create users -r asunset -s "username=$ADMIN_USER" -s enabled=true -s emailVerified=true >/dev/null 2>&1 || true
  kc set-password -r asunset --username "$ADMIN_USER" --new-password "$ADMIN_PASS"
  AU=$(kc get users -r asunset -q "username=$ADMIN_USER" --fields id --format csv --noquotes | tr -d '\r\n"')
  kc update "users/$AU" -r asunset -s 'requiredActions=[]'
  kc add-roles -r asunset --uusername="$ADMIN_USER" --rolename=platform_admin || true
  run ./bin/realm-doctor.sh >/dev/null 2>&1 || dfail "realm is not coherent — check ./bin/realm-doctor.sh"

  note "installing:checking the configuration is complete"
  config_precheck || dfail "the configuration this instance would boot with is incomplete: ${CONFIG_GAPS:-see $INSTALL_LOG}"

  note "installing:starting the product (pulled images — no build)"
  if ! run $DC up -d --wait --wait-timeout 900 >>"$INSTALL_LOG" 2>&1; then
    # An api that REFUSES to boot (missing config, D9) says so on its first
    # lines — put them where the browser is already pointing.
    run $DC logs --tail 40 opsroom-api >>"$INSTALL_LOG" 2>&1 || true
    dfail "the stack did not come up healthy — see $INSTALL_LOG"
  fi

  # The full up RE-RUNS the keycloak-init one-shot, which RESETS session
  # lifespans to the shipped 900s on every run (the known regression the
  # private repo's up.sh guards the same way). Re-apply AFTER the up, and
  # re-gate on realm-doctor so any other reset is caught too. Found live:
  # the first pull-path instance logged its admin out after 15 minutes,
  # 2026-08-30 — the doctor had passed BEFORE the reset happened behind it.
  note "installing:re-applying realm session settings"
  run ./bin/kc-session-lifespans.sh >/dev/null 2>&1 || true
  run ./bin/realm-doctor.sh >/dev/null 2>&1 || dfail "realm incoherent after full up — check ./bin/realm-doctor.sh"

  note "installing:creating the instance home"
  run $DC --profile ops run --rm --no-deps opsroom-init >>"$INSTALL_LOG" 2>&1 || dfail "opsroom-init failed — see $INSTALL_LOG"

  note "installing:identity-plane schema"
  # The asunset chain ships INSIDE the api image; run it from there with
  # the owner DSN (boot-proof discovery — no source tree needed).
  APP_OWNER=$(grep '^APP_DB_OWNER=' .env | cut -d= -f2); APP_OPW=$(grep '^APP_DB_OWNER_PASSWORD=' .env | cut -d= -f2)
  APP_DB=$(grep '^APP_DB_NAME=' .env | cut -d= -f2)
  run $DC run --rm --no-deps \
    --workdir /opt/opsroom/vendor/asunset/apps/api \
    -e ASUNSET_PG_DSN="postgresql://${APP_OWNER}:${APP_OPW}@postgres:5432/${APP_DB}" \
    -e DATABASE_URL="postgresql://${APP_OWNER}:${APP_OPW}@postgres:5432/${APP_DB}" \
    opsroom-api alembic upgrade head >>"$INSTALL_LOG" 2>&1 || dfail "identity schema failed — see $INSTALL_LOG"

  note "installing:first backup"
  run ./backup/backup.sh >>"$INSTALL_LOG" 2>&1 || note "installing:first backup FAILED (continuing — fix backups after login)"

  note "installing:final checks"
  # No green behind a failure: the handover means the gate passed.
  gate || dfail "final checks failed (compose health / api healthz / realm) — see $INSTALL_LOG"
  mkdir -p /etc/opsroom
  { grep '^OPSROOM_TAG=' release.env; echo "DEPLOY_COMMIT=$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"; } > /etc/opsroom/versions

  note "done:https://${TS_DNS}/"
  sleep 5
  handover
  exit 0
fi

# ════════════════════════════════════════════════════════════════════════
# --fresh: wipe THIS project for a clean re-run. Containers, volumes, the
# generated .env, the setup dir. The age key requires its own consent.
# ════════════════════════════════════════════════════════════════════════
if [ "${1:-}" = "--fresh" ]; then
  HOME_DIR=$(getent passwd "$OPS_USER" | cut -d: -f6 || true)
  REPO_DIR="${HOME_DIR:-/home/$OPS_USER}/opsroom-deploy"
  say "wiping the opsroom project"
  if [ -d "$REPO_DIR" ]; then
    # compose must PARSE the file to run down; supply the guarded vars
    # from .env when it exists, throwaway values when it does not.
    if [ -f "$REPO_DIR/.env" ]; then
      (cd "$REPO_DIR" && docker compose --env-file release.env --env-file .env --profile ops down -v --remove-orphans 2>/dev/null) || true
    else
      (cd "$REPO_DIR" && env OPSROOM_ORG=x OPSROOM_PROJECT=x OPSROOM_TEAM=x \
         OPSROOM_PG_PASSWORD=x OPSROOM_PUBLIC_ORIGIN=x OPENFGA_API_KEY=x \
         APP_DB_NAME=x APP_DB_OWNER=x APP_DB_OWNER_PASSWORD=x \
         docker compose --env-file release.env --profile ops down -v --remove-orphans 2>/dev/null) || true
    fi
    rm -f "$REPO_DIR/.env"
  fi
  rm -rf "$SETUP_DIR"; rm -f "$STATUS_FILE"
  rm -f /etc/opsroom/versions   # else --upgrade reads the pin of an install that is gone
  tailscale serve reset >/dev/null 2>&1 || true
  if [ -f "${HOME_DIR:-}/.config/sops/age/keys.txt" ]; then
    if [ "${2:-}" = "--and-the-age-key" ]; then
      shred -u "$HOME_DIR/.config/sops/age/keys.txt" 2>/dev/null || rm -f "$HOME_DIR/.config/sops/age/keys.txt"
      ok "age key destroyed (you said so explicitly)"
    else
      ok "age key KEPT ($HOME_DIR/.config/sops/age/keys.txt). If it encrypted any backup you still need it. To destroy: --fresh --and-the-age-key"
    fi
  fi
  ok "fresh. Re-run: sudo bash install.sh"
  exit 0
fi

# ════════════════════════════════════════════════════════════════════════
# --upgrade: auth first, snapshot before migrating, pull to completion
# before touching services (contract 141 §7).
# ════════════════════════════════════════════════════════════════════════
if [ "${1:-}" = "--upgrade" ]; then
  HOME_DIR=$(getent passwd "$OPS_USER" | cut -d: -f6)
  REPO_DIR="$HOME_DIR/opsroom-deploy"
  cd "$REPO_DIR" || die "no install at $REPO_DIR"
  run() { sudo -u "$OPS_USER" env PATH="/usr/local/bin:$PATH" HOME="$HOME_DIR" "$@"; }
  DC="docker compose --env-file release.env --env-file .env"
  say "1/6 registry auth"
  run docker pull -q "$(grep '^OPSROOM_REGISTRY=' release.env | cut -d= -f2)/opsroom-api:$(grep '^OPSROOM_TAG=' release.env | cut -d= -f2)" >/dev/null \
    || die "registry pull failed — is the token still valid? (docker login ${REGISTRY_HOST})"
  say "2/6 upgrade window (upgrades.json)"
  CUR_TAG=$(grep '^OPSROOM_TAG=' /etc/opsroom/versions 2>/dev/null | cut -d= -f2 || true)
  if grep -q '"breaking": *true' upgrades.json 2>/dev/null; then
    python3 - "$CUR_TAG" <<'PYEOF' || { printf 'Continue anyway? [y/N] '; read -r a </dev/tty; [ "$a" = y ] || exit 1; }
import json, sys
cur = sys.argv[1]
d = json.load(open("upgrades.json"))
bad = [e for e in d.get("entries", []) if e.get("breaking")]
if bad:
    print("BREAKING entries exist since your installed version (%s):" % (cur or "unknown"))
    for e in bad:
        print("  -", e.get("product_tag"), "|", e.get("notes", ""))
    sys.exit(1)
PYEOF
  fi
  say "3/6 pre-upgrade snapshot"
  mkdir -p backups
  STAMP=$(date -u +%Y%m%dT%H%M%SZ)
  run bash -c "$DC exec -T postgres pg_dumpall -U postgres | gzip > backups/pre-upgrade-identity-$STAMP.sql.gz"
  run bash -c "$DC exec -T opsroom-postgres pg_dumpall -U opsroom | gzip > backups/pre-upgrade-product-$STAMP.sql.gz"
  ok "backups/pre-upgrade-*-$STAMP.sql.gz"
  say "4/6 new orchestration"
  if grep -q '^OPSROOM_TAG=' .env 2>/dev/null; then
    echo "    ! your .env pins OPSROOM_TAG and OVERRIDES the tracked release pin — a restore sets that pin deliberately (and a rollback hold does too). Remove the line when you mean to move forward."
  fi
  run git pull --ff-only
  ensure_trio .env || die "fix .env, then re-run --upgrade (nothing was pulled or recreated)"
  say "5/6 pull to completion, then recreate"
  run $DC pull -q
  # AFTER the pull, because the NEW image's manifest is the one that matters:
  # a release that adds a required row would otherwise be found by the boot
  # refusal instead of here, with the old containers already gone.
  config_precheck || die "the new version requires configuration this instance does not have: ${CONFIG_GAPS:-see $INSTALL_LOG}
  Nothing was recreated — the running instance is untouched. Add what is named above to .env, then re-run --upgrade."
  run $DC up -d --wait --wait-timeout 900 || { run $DC logs --tail 40 opsroom-api || true; die "the stack did not come up healthy after the upgrade — version NOT recorded. Rollback: set OPSROOM_TAG=<previous> in .env (see versions.md), then: $DC pull && $DC up -d"; }
  say "6/6 gate, then record"
  # The version is recorded AFTER the gate passes — a red gate leaves
  # /etc/opsroom/versions at the previous pin, which is the truth.
  gate || die "the gate FAILED after the upgrade (see $INSTALL_LOG) — version NOT recorded. Rollback: set OPSROOM_TAG=<previous> in .env (see versions.md), then: $DC pull && $DC up -d"
  { grep '^OPSROOM_TAG=' release.env; echo "DEPLOY_COMMIT=$(git rev-parse --short HEAD)"; } > /etc/opsroom/versions
  docker image prune -f >/dev/null   # dangling only; OLD TAGGED images stay = your rollback
  ok "upgraded. Rollback: set OPSROOM_TAG=<previous> in .env (see versions.md), then: $DC pull && $DC up -d"
  exit 0
fi

# ── --restore: the SAME front half, a different form ──────────────────────
# A restore needs everything an install needs (the tools, the tailnet, the
# orchestration, a browser that can reach it) and then asks three different
# questions. So it is not a separate path — it is this path with a flag, and
# the deploy phase branches on it. One front half means the restore cannot
# rot behind the install.
RESTORE=0
if [ "${1:-}" = "--restore" ]; then
  RESTORE=1
  # REFUSE OVER A LIVING INSTANCE. Restoring here would replay one instance's
  # databases into another's, and the first sign would be someone else's data.
  RHOME=$(getent passwd "$OPS_USER" 2>/dev/null | cut -d: -f6 || true)
  if [ -n "$RHOME" ] && [ -f "$RHOME/opsroom-deploy/.env" ] \
     && docker volume inspect opsroom_postgres-data >/dev/null 2>&1; then
    die "this machine already runs an instance ($RHOME/opsroom-deploy/.env exists and its volumes are here).
  A restore would replay a backup over it. If that instance is finished with:
    sudo bash install.sh --fresh          (keeps the age key)
  then run --restore again. If it is NOT finished with, restore on another box."
  fi
fi

# ════════════════════════════════════════════════════════════════════════
# FRONT HALF — runs in your terminal, ends at a URL, then exits.
# ════════════════════════════════════════════════════════════════════════

# ── 1. the registry pull token — OPTIONAL here (deploy-v0.2.0) ─────────────
# The terminal asks for ONE thing: the tailscale key. The pull token
# normally goes into the browser form, where a typo is a field error and
# a retry is free. Providing it here (env or --token-file — unattended /
# cloud-init) keeps the old behavior: validate now, pull early.
PULL_TOKEN="${OPSROOM_PULL_TOKEN:-}"
if [ "${1:-}" = "--token-file" ] && [ -n "${2:-}" ]; then
  PULL_TOKEN=$(cat "$2") || die "cannot read token file $2"
fi
PULLED=0
if [ -n "$PULL_TOKEN" ]; then
  say "registry (token provided up front)"
  RTOK=$(curl -fsS -u "x:$PULL_TOKEN" "https://${REGISTRY_HOST}/token?scope=repository:${REGISTRY_NS}/opsroom-api:pull&service=${REGISTRY_HOST}" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])' 2>/dev/null) || die "the registry rejected the token"
  curl -fsS -o /dev/null -H "Authorization: Bearer $RTOK" \
    "https://${REGISTRY_HOST}/v2/${REGISTRY_NS}/opsroom-api/tags/list" \
    || die "token authenticates but cannot read images — it needs pull (read) access"
  ok "token verified against ${REGISTRY_HOST}/${REGISTRY_NS}"
  PULLED=1
fi

# ── 2. the tailscale key ───────────────────────────────────────────────────
TS_AUTHKEY="${TS_AUTHKEY:-}"
# `[ -r /dev/tty ]` LIES over non-interactive ssh — test an actual open.
if [ -z "$TS_AUTHKEY" ] && { : > /dev/tty; } 2>/dev/null; then
  printf 'Tailscale auth key (login.tailscale.com/admin/settings/keys — single-use, spent on join): ' > /dev/tty
  IFS= read -rs TS_AUTHKEY < /dev/tty; printf '\n' > /dev/tty
fi
TS_JOINED=$(command -v tailscale >/dev/null 2>&1 && tailscale status --json 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null || true)
if [ "$TS_JOINED" != Running ]; then
  [ -n "$TS_AUTHKEY" ] || die "no Tailscale auth key. Set TS_AUTHKEY=... for unattended runs."
  case "$TS_AUTHKEY" in tskey-*) ;; *) die "that does not look like a Tailscale auth key (expected tskey-...)";; esac
fi

# ── 3. the operator account ────────────────────────────────────────────────
say "operator account: $OPS_USER"
id "$OPS_USER" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$OPS_USER"
getent group docker >/dev/null || groupadd docker
usermod -aG sudo,docker "$OPS_USER"
HOME_DIR=$(getent passwd "$OPS_USER" | cut -d: -f6)
mkdir -p "$HOME_DIR"; chown -R "$OPS_USER:$OPS_USER" "$HOME_DIR"; chmod 750 "$HOME_DIR"
ok "$OPS_USER in sudo, docker; owns $HOME_DIR"

# ── 4. tools ───────────────────────────────────────────────────────────────
say "tools"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg git openssl gpg unzip python3 age >/dev/null
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
  systemctl enable --now docker >/dev/null 2>&1 || true
fi
ok "docker $(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
if ! command -v aws >/dev/null; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip
  (cd /tmp && unzip -q -o awscliv2.zip && ./aws/install --update >/dev/null 2>&1)
  rm -rf /tmp/aws /tmp/awscliv2.zip
fi
command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1
for t in docker aws age-keygen openssl curl git python3 tailscale; do
  command -v "$t" >/dev/null || die "still missing after install: $t"
done
ok "every tool this repo's scripts call is on PATH"

# ── 5. the tailnet ─────────────────────────────────────────────────────────
say "tailnet"
TS_STATE=$(tailscale status --json 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null || true)
if [ "$TS_STATE" = Running ]; then
  tailscale set --hostname="$TS_HOSTNAME" >/dev/null 2>&1 || true
  sleep 2
  ok "already on the tailnet — key not needed"
else
  AKF=$(mktemp); chmod 600 "$AKF"; printf '%s' "$TS_AUTHKEY" > "$AKF"
  if ! TS_ERR=$(tailscale up --authkey="file:$AKF" --hostname="$TS_HOSTNAME" --ssh=false 2>&1); then
    shred -u "$AKF" 2>/dev/null || rm -f "$AKF"
    printf '%s\n' "$TS_ERR" | sed 's/^/    /' >&2
    die "tailscale up failed. Auth keys are single-use — a key from a previous run is spent; mint a fresh one."
  fi
  shred -u "$AKF" 2>/dev/null || rm -f "$AKF"
fi
TS_DNS=$(tailscale status --json | python3 -c 'import sys,json; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || true)
[ -n "$TS_DNS" ] || die "joined the tailnet but could not read Self.DNSName"
ok "https://${TS_DNS}/"

# ── 6. this repo (PUBLIC — no deploy keys, no auth) ────────────────────────
say "orchestration"
REPO_DIR="$HOME_DIR/opsroom-deploy"
if [ ! -d "$REPO_DIR/.git" ]; then
  sudo -u "$OPS_USER" git clone -q "$REPO_HTTPS" "$REPO_DIR" || {
    TARBALL="${REPO_HTTPS%.git}/archive/refs/heads/main.tar.gz"
    mkdir -p "$REPO_DIR" && curl -fsSL "$TARBALL" | tar -xz --strip-components=1 -C "$REPO_DIR" \
      || die "could not fetch the deploy repo (git and tarball both failed)"
    chown -R "$OPS_USER:$OPS_USER" "$REPO_DIR"
  }
else
  sudo -u "$OPS_USER" git -C "$REPO_DIR" pull --ff-only -q || true
fi
git config --system --add safe.directory "$REPO_DIR" 2>/dev/null || true
ok "$(cd "$REPO_DIR" && git log -1 --format='%h %s' 2>/dev/null | cut -c1-50 || echo tarball)"

# ── 7. early pull — ONLY when the token came up front (unattended path) ────
if [ "$PULLED" = 1 ]; then
  say "images (early pull — token was provided up front)"
  printf '%s' "$PULL_TOKEN" | sudo -u "$OPS_USER" docker login "$REGISTRY_HOST" -u "${OPSROOM_PULL_USER:-$REGISTRY_NS}" --password-stdin >/dev/null \
    || die "docker login failed for the ops user"
  # The compose file's ${VAR:?} guards protect RUNNING with unset values;
  # pulling only needs the image refs, so the guarded non-pin vars get
  # throwaway values here (the deploy phase generates the real ones).
  ( cd "$REPO_DIR" && sudo -u "$OPS_USER" env \
      OPSROOM_ORG=x OPSROOM_PROJECT=x OPSROOM_TEAM=x OPSROOM_PG_PASSWORD=x \
      OPSROOM_PUBLIC_ORIGIN=x OPENFGA_API_KEY=x \
      APP_DB_NAME=x APP_DB_OWNER=x APP_DB_OWNER_PASSWORD=x \
      docker compose --env-file release.env pull -q ) \
    || die "image pull failed — check the token and release.env's pin"
  ok "all images pulled at $(grep '^OPSROOM_TAG=' "$REPO_DIR/release.env" | cut -d= -f2)"
else
  say "images"
  ok "deferred — the pull runs as the install's first step, with the token from the form"
fi

# ── 8. serve the form, print the URL, and EXIT ─────────────────────────────
say "setup"
rm -rf "$SETUP_DIR"; mkdir -p "$SETUP_DIR"; chmod 700 "$SETUP_DIR"
cp "$REPO_DIR"/setup/index.html "$REPO_DIR"/setup/installing.html "$REPO_DIR"/setup/server.py "$SETUP_DIR"/
SELF_COPY="$SETUP_DIR/install.sh"; cp "$REPO_DIR/install.sh" "$SELF_COPY" 2>/dev/null || cp "$0" "$SELF_COPY"
ANSWERS="$SETUP_DIR/answers.json"
: > "$STATUS_FILE"; chmod 644 "$STATUS_FILE"
: > "$INSTALL_LOG"; chmod 644 "$INSTALL_LOG"
setsid python3 "$SETUP_DIR/server.py" "$SETUP_DIR" "$ANSWERS" "$SETUP_PORT" "$STATUS_FILE" "$SELF_COPY" "$REPO_DIR" "$TS_DNS" "$OPS_USER" "$INSTALL_LOG" \
  "$REGISTRY_HOST" "$REGISTRY_NS" "$PULLED" "$RESTORE" \
  </dev/null >>"$INSTALL_LOG" 2>&1 &
sleep 1
tailscale serve --https=443 off >/dev/null 2>&1 || true
tailscale serve --bg --https=443 "http://127.0.0.1:${SETUP_PORT}" >/dev/null 2>&1 || die "tailscale serve failed"

if [ "$RESTORE" = 1 ]; then
  ok "restore is ready"
  cat <<EOF

    Open this on any device on your tailnet:

      https://${TS_DNS}/

    It asks which backup, and for the two keys from your password manager:
    the backup passphrase and the AGE-SECRET-KEY. Everything else comes back
    from the backup. The page shows progress and drops you into the restored
    instance. You can close this terminal; the restore does not run in it.
    (Follow along if you like: tail -f $INSTALL_LOG)
EOF
else
  ok "setup is ready"
  cat <<EOF

    Open this on any device on your tailnet, and fill the form:

      https://${TS_DNS}/

    It installs itself from there — the page shows progress and drops you
    into OpsRoom when it is done. You can close this terminal; the install
    does not run in it. (Follow along if you like: tail -f $INSTALL_LOG)
EOF
fi
