#!/usr/bin/env bash
# Set the realm's BROWSER session lifespans — the desktop half of report 122.
#
# WHY: the realm ships ssoSessionIdleTimeout=900. Fifteen minutes of not
# touching the UI and your SSO session dies, which is what defeats the
# silent refresh the SPA already does and throws you back to login while
# you are thinking. Avi's ruling (122 §1): sessions RENEW rather than
# expiring into a re-entry ceremony — and on the browser surface the
# renewal mechanism already exists; the idle timeout is what stops it
# working.
#
# WHAT IT DOES NOT TOUCH, deliberately: accessTokenLifespan (900). A short
# access token that is silently refreshed IS the renewal principle working
# correctly — lengthening it would replace an active re-check with a longer
# fixed grant, which is the trade 122 §3.1 exists to refuse. The knob that
# was hurting you is the IDLE timeout, not the token's life.
#
# BURDEN OF PROOF, per 122 §1: this is the surface where a PRESENT human
# extends their OWN session and their presence is the evidence. The agent
# half carries every condition in §3; this half carries almost none. Do not
# read one as precedent for the other.
#
#   ./bin/kc-session-lifespans.sh            # apply the defaults below
#   ./bin/kc-session-lifespans.sh 28800 43200 # idle, max (seconds)
#   ./bin/kc-session-lifespans.sh --show     # read current values, change nothing

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
[ -f .env ] || { echo "✗ no root .env"; exit 1; }

# 8h idle / 12h absolute: a workday without a surprise logout, still bounded,
# and the max still forces a daily re-authentication.
IDLE="${1:-28800}"
MAX="${2:-43200}"
SHOW_ONLY=0
[ "${1:-}" = "--show" ] && { SHOW_ONLY=1; IDLE=28800; MAX=43200; }

COMPOSE=(docker compose --env-file release.env --env-file .env)

REALM=$(grep '^KEYCLOAK_REALM=' .env | cut -d= -f2); REALM=${REALM:-asunset}
PW=$(grep '^KEYCLOAK_ADMIN_PASSWORD=' .env | cut -d= -f2)
[ -n "$PW" ] || { echo "✗ KEYCLOAK_ADMIN_PASSWORD not in .env"; exit 1; }

kc() { "${COMPOSE[@]}" exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"; }

quiet() { # capture; a FAILURE replays its output (the pin-loopback lesson)
  local log; log=$(mktemp)
  if "$@" >"$log" 2>&1; then rm -f "$log"; return 0; fi
  sed 's/^/    | /' "$log"; rm -f "$log"; return 1
}

quiet kc config credentials --server http://localhost:8080/auth \
    --realm master --user admin --password "$PW" \
  || { echo "✗ kcadm login failed (its output is above)"; exit 1; }

read_current() {
  kc get "realms/${REALM}" 2>/dev/null | python3 -c "
import sys, json
r = json.load(sys.stdin)
for k in ('ssoSessionIdleTimeout','ssoSessionMaxLifespan','accessTokenLifespan'):
    print(f'    {k} = {r.get(k)}')
" 2>/dev/null
}

echo "==> current (realm ${REALM})"
read_current

if [ "$SHOW_ONLY" = "1" ]; then exit 0; fi

echo
echo "==> setting idle=${IDLE}s ($((IDLE/3600))h)  max=${MAX}s ($((MAX/3600))h)"
quiet kc update "realms/${REALM}" \
    -s "ssoSessionIdleTimeout=${IDLE}" \
    -s "ssoSessionMaxLifespan=${MAX}" \
  || { echo "✗ update failed (its output is above)"; exit 1; }

# VERIFY BY READING, never by echoing the exit code — the realm is the
# authority on what the realm now says.
echo
echo "==> read back"
AFTER=$(kc get "realms/${REALM}" 2>/dev/null | python3 -c "
import sys, json
r = json.load(sys.stdin)
print(r.get('ssoSessionIdleTimeout'), r.get('ssoSessionMaxLifespan'), r.get('accessTokenLifespan'))
" 2>/dev/null)
read -r GOT_IDLE GOT_MAX GOT_ATL <<<"$AFTER"
read_current

if [ "$GOT_IDLE" = "$IDLE" ] && [ "$GOT_MAX" = "$MAX" ]; then
  echo "    ✓ applied and read back"
else
  echo "    ✗ read-back does not match (wanted ${IDLE}/${MAX}, got ${GOT_IDLE}/${GOT_MAX})"
  exit 1
fi
[ "$GOT_ATL" = "900" ] || echo "    ! accessTokenLifespan is ${GOT_ATL}, not the shipped 900 — this script does not set it; something else did"

echo
echo "================ DONE ================"
echo "  Existing browser sessions keep their old idle window until they end."
echo "  No service restart needed — the realm is read live."
echo "  keycloak-init resets these on every run, so pin-loopback.sh (2c) and"
echo "  r4-tailnet.sh call this script after their init step — the revert is"
echo "  repaired by the scripts that cause it, not by remembering."
