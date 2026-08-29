#!/usr/bin/env bash
# Keycloak post-import bootstrap — runs once per `up` after the realm
# import completes. Mounted into the keycloak-init container by every
# overlay so behavior diffs by env var, not by replacing the script.
#
# Why a script and not inline `command:` blocks: docker compose merges
# `command:` as REPLACE, not append. Inline scripts in compose.yml meant
# every overlay had to re-paste the whole body, and any change to the
# base silently dropped on tailscale/TLS deployments. Mounting one file
# means overlays just flip env vars (KC_AUTH_URL, WEB_BASE_URL).
#
# Env contract:
#   KEYCLOAK_ADMIN, KEYCLOAK_ADMIN_PASSWORD     — bootstrap creds (always set)
#   KEYCLOAK_REALM                              — realm name (always set)
#   KEYCLOAK_API_CLIENT_SECRET                  — synced into asunset-api client
#   KC_AUTH_URL   (default http://keycloak:8080) — base URL for kcadm; tailscale
#                                                  overlay sets …:8080/auth
#   WEB_BASE_URL  (optional)                    — when set, rewrite asunset-web's
#                                                  redirect_uris/web_origins to it;
#                                                  if it starts with https://, also
#                                                  lock realm sslRequired=all
#   KC_SMTP_HOST  (optional)                    — when set, configure realm SMTP;
#                                                  empty = local dev / no email
#   KEYCLOAK_EXTRA_AUDIENCES (optional)         — comma-separated audience values
#                                                  added to asunset-web access
#                                                  tokens (identity-contract D6:
#                                                  one entry per resource server,
#                                                  e.g. "opsroom-api,opsroom-mcp,
#                                                  orchestration"). Idempotent.

set -euo pipefail

KC_AUTH_URL="${KC_AUTH_URL:-http://keycloak:8080}"
KCADM=/opt/keycloak/bin/kcadm.sh

"$KCADM" config credentials \
  --server "$KC_AUTH_URL" \
  --realm master \
  --user "$KEYCLOAK_ADMIN" \
  --password "$KEYCLOAK_ADMIN_PASSWORD"

# --- asunset-api: sync client secret from env ---------------------------
API_UUID="$("$KCADM" get clients -r "$KEYCLOAK_REALM" -q clientId=asunset-api --fields id --format csv --noquotes | tr -d '\r\n')"
if [ -z "$API_UUID" ]; then
  echo "keycloak-init: asunset-api client not found" >&2
  exit 1
fi
"$KCADM" update "clients/$API_UUID" \
  -r "$KEYCLOAK_REALM" \
  -s "secret=$KEYCLOAK_API_CLIENT_SECRET"
echo "keycloak-init: asunset-api secret synced from env"

# --- asunset-api service account: grant manage-users --------------------
# Required for the invite flow (create user, send actions email).
# add-roles is idempotent — `|| true` covers the "already assigned" 409.
"$KCADM" add-roles -r "$KEYCLOAK_REALM" \
  --uusername=service-account-asunset-api \
  --cclientid=realm-management \
  --rolename=manage-users 2>/dev/null || true
echo "keycloak-init: asunset-api service account has manage-users"

# --- the machine operator identity (v1.1 / feature-ops) ------------------
# The asunset-api service account IS the doctor/on-call machine identity:
#   1. platform_support realm role → may call read-tier + freeze-tier
#      endpoints (reconcile dry_run, feature freeze/unfreeze) — the
#      identity contract's machines-lane, no new roles minted.
#   2. an audience mapper on asunset-api so its client_credentials
#      tokens carry aud=asunset-api and validate through the normal
#      contract §5 path.
# Token custody for 2am: the credentials are the box's own .env
# (KEYCLOAK_API_CLIENT_ID/SECRET) — see docs/runbooks/feature-freeze.md.
"$KCADM" add-roles -r "$KEYCLOAK_REALM" \
  --uusername=service-account-asunset-api \
  --rolename=platform_support 2>/dev/null || true
echo "keycloak-init: asunset-api service account has platform_support (operator identity)"

API_MAPPERS="$("$KCADM" get "clients/$API_UUID/protocol-mappers/models" -r "$KEYCLOAK_REALM" --fields name --format csv --noquotes 2>/dev/null | tr -d '\r"')"
if echo "$API_MAPPERS" | grep -qx "audience-self"; then
  echo "keycloak-init: asunset-api audience-self mapper already present — skipping"
else
  "$KCADM" create "clients/$API_UUID/protocol-mappers/models" \
    -r "$KEYCLOAK_REALM" \
    -s "name=audience-self" \
    -s "protocol=openid-connect" \
    -s "protocolMapper=oidc-audience-mapper" \
    -s 'config."included.client.audience"=asunset-api' \
    -s 'config."access.token.claim"=true' \
    -s 'config."id.token.claim"=false'
  echo "keycloak-init: asunset-api audience-self mapper added (service-account tokens validate)"
fi

# --- realm: session + OTP policy ----------------------------------------
# --import-realm uses IGNORE_EXISTING on re-boots, so realm-export.json
# tweaks don't propagate after first import. Push HIPAA/NYDFS knobs via
# kcadm so they land on every start.
"$KCADM" update "realms/$KEYCLOAK_REALM" \
  -s "ssoSessionIdleTimeout=900" \
  -s "ssoSessionMaxLifespan=14400" \
  -s "otpPolicyType=totp" \
  -s "otpPolicyAlgorithm=HmacSHA1" \
  -s "otpPolicyDigits=6" \
  -s "otpPolicyPeriod=30" \
  -s "otpPolicyLookAheadWindow=1" \
  -s "revokeRefreshToken=true" \
  -s "refreshTokenMaxReuse=0"
echo "keycloak-init: realm session + OTP + refresh-rotation policy updated"

# --- asunset-web: rewrite URIs to deployment hostname -------------------
# The realm export ships dev-default URIs (http://localhost:3000 +
# :5173). Every non-plain deployment MUST overwrite them or Keycloak
# rejects login with an opaque "Invalid parameter: redirect_uri".
#
# The TLS/tailscale overlays set WEB_BASE_URL directly. But relying on a
# single var threading through a compose overlay is fragile: if it's
# unset for any reason on a remote deploy, the client silently keeps the
# localhost dev URIs (wirebit-crm-client hit exactly this on the first
# tailnet bootstrap). So: derive WEB_BASE_URL from TAILSCALE_HOST when
# it's not already set, and refuse to leave localhost URIs on a clearly
# remote (tailnet) deployment rather than failing silently at login.
WEB_BASE_URL="${WEB_BASE_URL:-}"
# A remote host declared by either overlay is the authoritative source.
REMOTE_HOST="${TAILSCALE_HOST:-${TLS_WEB_HOST:-}}"
if [ -z "$WEB_BASE_URL" ] && [ -n "$REMOTE_HOST" ]; then
  WEB_BASE_URL="https://${REMOTE_HOST}"
  echo "keycloak-init: derived WEB_BASE_URL=$WEB_BASE_URL from remote host"
fi
# An empty-host interpolation ("https://" with nothing after it) is the
# TLS-mode flavor of the same landmine — treat it as unset.
if [ "$WEB_BASE_URL" = "https://" ] || [ "$WEB_BASE_URL" = "http://" ]; then
  WEB_BASE_URL=""
fi

# Fail loud on the landmine: a remote deploy (tailnet or TLS host set)
# whose resolved web base is still localhost/empty would ship broken
# redirect URIs. Stop here with a clear message instead of a runtime
# login failure.
case "$WEB_BASE_URL" in
  http://localhost*|http://127.0.0.1*|"")
    if [ -n "$REMOTE_HOST" ]; then
      echo "keycloak-init: FATAL — remote host '$REMOTE_HOST' declared (TAILSCALE_HOST/TLS_WEB_HOST) but WEB_BASE_URL resolved to '${WEB_BASE_URL:-<empty>}'; refusing to configure asunset-web with localhost redirect URIs (would reject login with 'Invalid parameter: redirect_uri')" >&2
      exit 1
    fi
    ;;
esac

if [ -n "$WEB_BASE_URL" ]; then
  WEB_UUID="$("$KCADM" get clients -r "$KEYCLOAK_REALM" -q clientId=asunset-web --fields id --format csv --noquotes | tr -d '\r\n')"

  # Optional dev-against-live origins (KC_DEV_WEB_ORIGINS, comma-separated
  # bare origins, e.g. "http://localhost:7501"). Sanctioned so a product's
  # vite dev server can run true HMR against a live stack WITHOUT the
  # manual kcadm edits being wiped by the next init re-run. Keycloak
  # validates three SEPARATE lists (redirect, web-origin, post-logout —
  # the third bites last, as field experience showed), so each origin
  # lands in all three or the flow 400s at sign-out.
  WEB_REDIRECTS="\"$WEB_BASE_URL/*\""
  WEB_ORIGINS="\"$WEB_BASE_URL\""
  WEB_POST_LOGOUT="$WEB_BASE_URL/*"
  if [ -n "${KC_DEV_WEB_ORIGINS:-}" ]; then
    OLDIFS=$IFS; IFS=','
    for _o in $KC_DEV_WEB_ORIGINS; do
      _o=$(echo $_o)  # trim surrounding whitespace
      [ -z "$_o" ] && continue
      WEB_REDIRECTS="$WEB_REDIRECTS,\"$_o/*\""
      WEB_ORIGINS="$WEB_ORIGINS,\"$_o\""
      WEB_POST_LOGOUT="$WEB_POST_LOGOUT##$_o/*"
    done
    IFS=$OLDIFS
    echo "keycloak-init: WARNING — dev web origins on asunset-web: $KC_DEV_WEB_ORIGINS (dev-against-live; unset KC_DEV_WEB_ORIGINS on production instances)"
  fi

  "$KCADM" update "clients/$WEB_UUID" \
    -r "$KEYCLOAK_REALM" \
    -s "rootUrl=$WEB_BASE_URL" \
    -s "baseUrl=$WEB_BASE_URL" \
    -s "redirectUris=[$WEB_REDIRECTS]" \
    -s "webOrigins=[$WEB_ORIGINS]" \
    -s "attributes.\"post.logout.redirect.uris\"=$WEB_POST_LOGOUT"
  echo "keycloak-init: asunset-web URIs → $WEB_BASE_URL"

  # When the deployment terminates TLS (TLS or tailscale modes both set
  # WEB_BASE_URL to https://…), force sslRequired=all so Keycloak refuses
  # cleartext on every channel.
  case "$WEB_BASE_URL" in
    https://*)
      "$KCADM" update "realms/$KEYCLOAK_REALM" -s "sslRequired=all"
      echo "keycloak-init: realm sslRequired=all"
      ;;
  esac
fi

# --- extra audiences: one aud entry per resource server (D6) -------------
# The realm export ships one audience mapper (asunset-api). Deployments
# with additional resource servers (product API gate, MCP, orchestration)
# list them in KEYCLOAK_EXTRA_AUDIENCES; each becomes an
# oidc-audience-mapper on asunset-web using included.custom.audience —
# custom, because these are audience STRINGS, not Keycloak clients
# (per D6: no per-RS clients unless a service needs its own outbound
# credential). Each RS then validates its OWN entry of the aud array.
# Idempotent by mapper name (audience-<value>); values are never removed
# here — removing an RS's audience is an explicit operator action.
if [ -n "${KEYCLOAK_EXTRA_AUDIENCES:-}" ]; then
  WEB_UUID="${WEB_UUID:-$("$KCADM" get clients -r "$KEYCLOAK_REALM" -q clientId=asunset-web --fields id --format csv --noquotes | tr -d '\r\n')}"
  EXISTING_MAPPERS="$("$KCADM" get "clients/$WEB_UUID/protocol-mappers/models" -r "$KEYCLOAK_REALM" --fields name --format csv --noquotes 2>/dev/null | tr -d '\r"')"
  OLD_IFS="$IFS"; IFS=','
  for AUD in $KEYCLOAK_EXTRA_AUDIENCES; do
    IFS="$OLD_IFS"
    AUD="$(echo "$AUD" | tr -d '[:space:]')"
    [ -z "$AUD" ] && continue
    if echo "$EXISTING_MAPPERS" | grep -qx "audience-$AUD"; then
      echo "keycloak-init: audience mapper audience-$AUD already present — skipping"
      continue
    fi
    "$KCADM" create "clients/$WEB_UUID/protocol-mappers/models" \
      -r "$KEYCLOAK_REALM" \
      -s "name=audience-$AUD" \
      -s "protocol=openid-connect" \
      -s "protocolMapper=oidc-audience-mapper" \
      -s 'config."included.custom.audience"='"$AUD" \
      -s 'config."access.token.claim"=true' \
      -s 'config."id.token.claim"=false'
    echo "keycloak-init: audience mapper added → $AUD"
  done
  IFS="$OLD_IFS"
else
  echo "keycloak-init: KEYCLOAK_EXTRA_AUDIENCES unset — token aud stays [asunset-api]"
fi

# --- TOTP enforcement on platform_admin holders -------------------------
# HIPAA §164.312(a)(2)(i) / NYDFS 500.12 — MFA on privileged accounts.
# Skip users who already have a TOTP credential — overwriting
# requiredActions on an enrolled user forces re-enrollment, which piles
# up orphan credentials and makes the OTP picker nondeterministic.
ADMIN_USERS="$("$KCADM" get "roles/platform_admin/users" -r "$KEYCLOAK_REALM" --fields username --format csv --noquotes 2>/dev/null | tr -d '\r"')"
for U in $ADMIN_USERS; do
  [ -z "$U" ] && continue
  # NB: can't use the name UID — readonly bash built-in (effective user
  # id); assignment silently aborts the whole script under `set -e`.
  USER_UID="$("$KCADM" get users -r "$KEYCLOAK_REALM" -q "username=$U" --fields id --format csv --noquotes | tr -d '\r\n"')"
  [ -z "$USER_UID" ] && continue
  HAS_TOTP="$("$KCADM" get "users/$USER_UID/credentials" -r "$KEYCLOAK_REALM" --fields type --format csv --noquotes 2>/dev/null | tr -d '\r"' | grep -cx 'otp' || true)"
  if [ "$HAS_TOTP" -gt 0 ]; then
    echo "keycloak-init: TOTP already enrolled for $U — skipping"
    continue
  fi
  "$KCADM" update "users/$USER_UID" \
    -r "$KEYCLOAK_REALM" \
    -s 'requiredActions=["CONFIGURE_TOTP"]' 2>/dev/null || true
  echo "keycloak-init: TOTP required for $U"
done

# --- realm SMTP ---------------------------------------------------------
# Drives Keycloak's own emails — verify-email, forgot-password, magic-link
# invites — separate from the app-side Notifier. Skip entirely if
# KC_SMTP_HOST is unset so local dev / CI never wires up real delivery by
# accident. Compatible with Resend SMTP (smtp.resend.com:587, user=resend,
# password=<api-key>, starttls=true).
#
# Bonus catch: `kcadm get realms/<realm> --fields smtpServer` returns
# `{}` on KC 25 even after a successful update — `--fields` has a quirk
# for nested objects. Values *are* persisted; verify by reading the full
# realm JSON without --fields, or trying a "Send test email" from the
# admin UI. Don't chase this red herring.
if [ -n "${KC_SMTP_HOST:-}" ]; then
  "$KCADM" update "realms/$KEYCLOAK_REALM" \
    -s "smtpServer.host=$KC_SMTP_HOST" \
    -s "smtpServer.port=${KC_SMTP_PORT:-587}" \
    -s "smtpServer.from=$KC_SMTP_FROM" \
    -s "smtpServer.fromDisplayName=${KC_SMTP_FROM_DISPLAY_NAME:-}" \
    -s "smtpServer.replyTo=${KC_SMTP_REPLY_TO:-}" \
    -s "smtpServer.ssl=${KC_SMTP_SSL:-false}" \
    -s "smtpServer.starttls=${KC_SMTP_STARTTLS:-true}" \
    -s "smtpServer.auth=${KC_SMTP_AUTH:-true}" \
    -s "smtpServer.user=${KC_SMTP_USER:-}" \
    -s "smtpServer.password=${KC_SMTP_PASSWORD:-}"
  echo "keycloak-init: realm SMTP configured ($KC_SMTP_HOST)"
else
  echo "keycloak-init: KC_SMTP_HOST unset — skipping realm SMTP (Keycloak emails disabled)"
fi
