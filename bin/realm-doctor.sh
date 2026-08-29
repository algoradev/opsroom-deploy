#!/usr/bin/env bash
# REALM COHERENCE — the properties that live only in a running Keycloak.
#
#   ./bin/realm-doctor.sh          # check; exit 1 on any FAIL
#   ./bin/realm-doctor.sh --json   # machine-readable
#
# WHY THIS EXISTS, AND WHY IT IS NOT IN doctor.py.
#
# DEPLOYME §5 ends on a class it names and does not check: "live-realm-only
# state — recorded in no file, lost on realm restore". On 2026-08-25 a cold
# start produced an instance where every container was healthy, the front
# door answered 200, and doctor said ok — while THREE members of that class
# were wrong at once:
#
#   · session lifespans were 900/14400, so the SPA logged you out every
#     15 minutes. Report 122 ruled 28800/43200. keycloak-init resets them
#     on EVERY run and nothing restores them.
#   · the audience mapper list held one entry where three belong, so the
#     engine would 401 every browser token with "wrong audience". Report 97
#     records that exact outage, in April, from that exact value.
#   · the device authorization grant was enabled on no client, so the
#     day-one ceremony aborts at step 0/4 with `unauthorized_client`.
#
# None was visible in a container status, an image id, or an exit code.
# Each presents as THE PRODUCT BEING BROKEN — "it keeps logging me out",
# "the engine rejects everything", "the ceremony will not authenticate" —
# and each was already written down somewhere. Being written down is what
# failed. So: ask the realm instead of hoping someone read the runbook.
#
# IT RUNS HOST-SIDE because that is where the credentials are. doctor.py
# runs in-stack with the asunset-api CLIENT credentials, which cannot read
# realm configuration; KEYCLOAK_ADMIN_PASSWORD lives in the repo's .env,
# which containers deliberately cannot see. Same reason secrets-seal and
# config-completeness are host-side (DEPLOYME §3's "+2").
#
# WHAT IT IS NOT: a presence contract. Report 113 already asks "is this
# set?" of the config file. Every failure above was a value that WAS set,
# validly, and was incoherent with something else — a mode needing SMTP
# with no SMTP, one audience where the deployment declares three, a grant
# the ceremony requires and no one enabled. This asks "do these agree?"
#
# EXPECTATIONS ARE DERIVED, NOT TYPED. The audience list comes from
# KEYCLOAK_EXTRA_AUDIENCES in .env, so adding a resource server updates
# the check for free. The lifespans come from bin/kc-session-lifespans.sh's
# own defaults, so the ruling has one home. A check with its own copy of the
# answer is a second place for the answer to be wrong.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

JSON=0
[ "${1:-}" = "--json" ] && JSON=1

[ -f .env ] || { echo "x no .env — run from a provisioned instance"; exit 1; }

REALM=$(grep -E '^KEYCLOAK_REALM=' .env | cut -d= -f2); REALM="${REALM:-asunset}"
KA=$(grep -E '^KEYCLOAK_ADMIN=' .env | cut -d= -f2)
KP=$(grep -E '^KEYCLOAK_ADMIN_PASSWORD=' .env | cut -d= -f2)
AUDS=$(grep -E '^KEYCLOAK_EXTRA_AUDIENCES=' .env | cut -d= -f2)
WEB_CLIENT=$(grep -E '^KEYCLOAK_WEB_CLIENT_ID=' .env | cut -d= -f2); WEB_CLIENT="${WEB_CLIENT:-asunset-web}"

# The ruled lifespans, read from the script that owns them rather than
# restated here (report 122 §1). If that ruling changes, it changes once.
WANT_IDLE=$(grep -E '^IDLE="\$\{1:-' bin/kc-session-lifespans.sh | sed 's/.*:-//; s/}".*//')
WANT_MAX=$(grep -E '^MAX="\$\{2:-'  bin/kc-session-lifespans.sh | sed 's/.*:-//; s/}".*//')

RESULTS=""; FAILED=0; NOTRUN=0
emit() { # name status detail
  RESULTS="${RESULTS}${1}|${2}|${3}"$'\n'
  [ "$2" = "fail" ] && FAILED=$((FAILED + 1))
  [ "$2" = "notrun" ] && NOTRUN=$((NOTRUN + 1))
  return 0
}

KCC="asunset-keycloak-1"
kc() { docker exec -i "$KCC" /opt/keycloak/bin/kcadm.sh "$@" 2>&1; }

if ! docker inspect "$KCC" >/dev/null 2>&1; then
  emit realm-reachable notrun "keycloak container $KCC not present — stack down?"
elif ! kc config credentials --server http://localhost:8080/auth --realm master \
        --user "$KA" --password "$KP" >/dev/null 2>&1; then
  # COULD-NOT-RUN, not pass. doctor.py's `evaluated` field exists for
  # exactly this distinction: a check that could not look is not a check
  # that looked and found nothing.
  emit realm-reachable notrun "kcadm could not authenticate as $KA"
else
  emit realm-reachable ok "authenticated to realm $REALM"

  # --- 1. session lifespans (report 122) -------------------------------
  RJSON=$(kc get "realms/${REALM}" 2>/dev/null)
  GOT_IDLE=$(printf '%s' "$RJSON" | tr ',' '\n' | grep -m1 '"ssoSessionIdleTimeout"' | sed 's/[^0-9]//g')
  GOT_MAX=$(printf '%s' "$RJSON" | tr ',' '\n' | grep -m1 '"ssoSessionMaxLifespan"' | sed 's/[^0-9]//g')
  if [ -z "$GOT_IDLE" ]; then
    emit session-lifespans notrun "could not read the realm"
  elif [ "$GOT_IDLE" = "$WANT_IDLE" ] && [ "$GOT_MAX" = "$WANT_MAX" ]; then
    emit session-lifespans ok "idle=${GOT_IDLE} max=${GOT_MAX} (report 122)"
  else
    emit session-lifespans fail \
      "idle=${GOT_IDLE} max=${GOT_MAX}, ruled ${WANT_IDLE}/${WANT_MAX} — keycloak-init resets these on EVERY run; fix: ./bin/kc-session-lifespans.sh"
  fi

  WEB_UUID=$(kc get clients -r "$REALM" -q "clientId=${WEB_CLIENT}" --fields id --format csv --noquotes 2>/dev/null | tr -d '\r\n"')
  if [ -z "$WEB_UUID" ]; then
    emit web-client notrun "client ${WEB_CLIENT} not found in realm ${REALM}"
  else
    # --- 2. audience mappers, DERIVED from what .env declares ----------
    MAPPERS=$(kc get "clients/${WEB_UUID}/protocol-mappers/models" -r "$REALM" \
                --fields name --format csv --noquotes 2>/dev/null | tr -d '\r"')
    if [ -z "$AUDS" ]; then
      emit audience-mappers ok "KEYCLOAK_EXTRA_AUDIENCES unset — nothing declared, nothing owed"
    else
      MISSING=""
      OLD_IFS="$IFS"; IFS=','
      for A in $AUDS; do
        A=$(printf '%s' "$A" | tr -d ' ')
        [ -n "$A" ] || continue
        printf '%s\n' "$MAPPERS" | grep -qx "audience-${A}" || MISSING="${MISSING}${A} "
      done
      IFS="$OLD_IFS"
      if [ -z "$MISSING" ]; then
        emit audience-mappers ok "all declared audiences have mappers: ${AUDS}"
      else
        emit audience-mappers fail \
          "declared but NOT mapped: ${MISSING}— the resource server 401s every token with 'wrong audience' (report 97); fix: set KEYCLOAK_EXTRA_AUDIENCES then re-run keycloak-init"
      fi
    fi

    # --- 3. device authorization grant, PROBED NOT READ ----------------
    # The day-one ceremony authenticates with it. Enabled by hand on
    # 2026-08-25; it is in no realm export and no init script, so a fresh
    # realm does not have it and r5a-bootstrap.sh aborts at step 0/4.
    #
    # THE FIRST VERSION OF THIS CHECK READ THE CONFIG AND WAS WRONG.
    # `kcadm get clients/<id> --fields attributes` returns `{ }` — an empty
    # object — while the SAME client's full JSON contains
    # "oauth2.device.authorization.grant.enabled" : "true". The projection
    # drops what you asked for and reports success, so the check confidently
    # failed a working instance on its first run. A guard that cries wolf
    # gets deleted by the third person who trips it, and this one nearly
    # earned it in an hour.
    #
    # So ask the ENDPOINT, exactly as auth-login-entry asks Keycloak whether
    # a login can start: the question is "can the ceremony authenticate",
    # and only the token endpoint answers that. PKCE is required by this
    # client, so the probe sends a real challenge; the device code it mints
    # is never redeemed and expires on its own.
    PUB=$(grep -E '^OPSROOM_PUBLIC_URL=' .env | cut -d= -f2 | tr -d '"' | sed 's|/*$||')
    if [ -z "$PUB" ]; then
      emit device-grant notrun "OPSROOM_PUBLIC_URL unset — cannot reach the device endpoint"
    else
      _v=$(openssl rand -base64 48 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
      _r=$(printf '%s' "$_v" | openssl dgst -binary -sha256 | openssl base64)
      _c=$(printf '%s' "$_r" | tr -d '\n' | tr '+/' '-_' | tr -d '=')
      PROBE=$(curl -sS --max-time 15 -X POST \
        "${PUB}/auth/realms/${REALM}/protocol/openid-connect/auth/device" \
        -d "client_id=${WEB_CLIENT}" -d "scope=openid" \
        -d "code_challenge=${_c}" -d "code_challenge_method=S256" 2>&1)
      case "$PROBE" in
        *device_code*)
          emit device-grant ok "endpoint mints a device_code — the ceremony can authenticate" ;;
        *unauthorized_client*|*"not allowed"*|*invalid_client*)
          emit device-grant fail \
            "the ${WEB_CLIENT} client refuses the device grant — the day-one ceremony aborts at 0/4; fix: kcadm update clients/${WEB_UUID} -r ${REALM} -s 'attributes.\"oauth2.device.authorization.grant.enabled\"=true'" ;;
        *)
          # THE ENDPOINT DID NOT ANSWER AS KEYCLOAK. Either the front door
          # is not up yet (a cold start probes before `tailscale serve`), or
          # :443 is currently serving something else — during the installer
          # it serves the SETUP FORM, so the probe gets back HTML. Both mean
          # "cannot ask the endpoint", so fall back to the realm rather than
          # reporting a connection error, or an HTML page, as a config
          # verdict. This is every non-OIDC response: connection refused,
          # empty, or a stray <!doctype html>.
          #
          # Read the FULL client json, never `--fields attributes`: that
          # projection returns `{ }` while the same client carries the
          # attribute, which made the first version of this check fail a
          # working instance. Measured, not assumed.
          ATTRS=$(kc get "clients/${WEB_UUID}" -r "$REALM" 2>/dev/null | tr -d ' \r"')
          case "$ATTRS" in
            *oauth2.device.authorization.grant.enabled:true*)
              emit device-grant ok "enabled in the realm (endpoint not answering as keycloak, so read from config)" ;;
            *)
              emit device-grant fail \
                "NOT enabled on ${WEB_CLIENT} — read from the realm, since the endpoint did not answer as keycloak. The day-one ceremony will abort at 0/4; fix: kcadm update clients/${WEB_UUID} -r ${REALM} -s 'attributes.\"oauth2.device.authorization.grant.enabled\"=true'" ;;
          esac ;;
      esac
    fi
  fi
fi

# --- 4. invite delivery is POSSIBLE, not merely valid -------------------
# Pure config coherence, so it runs even with the stack down. magic_link
# mails a one-time link; with no SMTP there is nothing to mail with, and
# every invite then succeeds and reaches no one — an instance that cannot
# onboard anybody while reporting healthy.
MODE=$(grep -E '^INVITE_DELIVERY=' .env | cut -d= -f2); MODE="${MODE:-temp_password}"
SMTP=$(grep -E '^KC_SMTP_HOST=' .env | cut -d= -f2)
case "$MODE" in
  magic_link)
    if [ -n "$SMTP" ]; then
      emit invite-deliverable ok "magic_link with KC_SMTP_HOST set"
    else
      emit invite-deliverable fail \
        "INVITE_DELIVERY=magic_link but KC_SMTP_HOST is empty — invites succeed and reach no one; fix: INVITE_DELIVERY=temp_password until SMTP exists"
    fi ;;
  auto)
    [ -n "$SMTP" ] && emit invite-deliverable ok "auto, SMTP present" \
      || emit invite-deliverable warn "auto with no SMTP — every invite silently falls back to temp_password; declaring temp_password says so out loud" ;;
  temp_password)
    emit invite-deliverable ok "temp_password — the admin shares the credential out of band" ;;
  *)
    emit invite-deliverable fail "INVITE_DELIVERY=${MODE} is not a recognised mode" ;;
esac

# --- output -------------------------------------------------------------
if [ "$JSON" = "1" ]; then
  printf '{"checks":['
  first=1
  while IFS='|' read -r n s d; do
    [ -n "$n" ] || continue
    [ $first -eq 1 ] || printf ','
    first=0
    printf '{"name":"%s","status":"%s","detail":"%s","evaluated":%s}' \
      "$n" "$s" "$(printf '%s' "$d" | sed 's/"/\\"/g')" \
      "$([ "$s" = notrun ] && echo false || echo true)"
  done <<< "$RESULTS"
  printf '],"ok":%s}\n' "$([ "$FAILED" -eq 0 ] && echo true || echo false)"
else
  while IFS='|' read -r n s d; do
    [ -n "$n" ] || continue
    case "$s" in
      ok)     g="ok  " ;;
      warn)   g="warn" ;;
      fail)   g="FAIL" ;;
      notrun) g="n/a " ;;
    esac
    printf '  [%s] %-20s %s\n' "$g" "$n" "$d"
  done <<< "$RESULTS"
  echo
  if [ "$FAILED" -gt 0 ]; then
    echo "  realm-doctor: ${FAILED} FAIL — these are live-realm-only state; a"
    echo "  realm restore or a keycloak-init re-run can reintroduce any of them."
  elif [ "$NOTRUN" -gt 0 ]; then
    echo "  realm-doctor: no failures, but ${NOTRUN} could NOT BE CHECKED —"
    echo "  which is not the same as passing."
  else
    echo "  realm-doctor: coherent"
  fi
fi

exit $([ "$FAILED" -eq 0 ] && echo 0 || echo 1)
