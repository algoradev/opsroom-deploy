# Version pins — dated, previous tag inline, for rollback reference

Hand-maintained (the Supabase discipline: no bot exists for this; the
release CI in the product repo fails a release whose migrations lack an
upgrades.json entry, which keeps this honest).

## 2026-08-28 — initial

- OPSROOM_TAG: 0.1.1 (prev: none — first published pin)
- deploy repo: deploy-v0.1.0
- note: 0.1.0 images exist but are NOT consumable — the
  asunset-keycloak-theme image at 0.1.0 is mis-built (product repo,
  board 140 goal 1). Never pin 0.1.0.

## 2026-08-30 — deploy-v0.1.1

- OPSROOM_TAG: 0.1.1 (unchanged)
- deploy repo: deploy-v0.1.1 (prev: deploy-v0.1.0)
- installer: KEYCLOAK_PUBLIC_URL now written (issuer mismatch on first
  login); session lifespans re-applied AFTER the full up (keycloak-init
  resets them on every run) with the realm-doctor gate moved after.
- compose: readiness gates hardened (spec 143 in the product repo) —
  openfga probed via grpc_health_probe with dependents on
  service_healthy; caddy healthchecked and healthy-gated; mcp gates on
  ready api; vector healthchecked ([api] added to vector.toml).

## 2026-08-30 — deploy-v0.2.0

- OPSROOM_TAG: 0.1.1 (unchanged)
- deploy repo: deploy-v0.2.0 (prev: deploy-v0.1.1)
- FLOW CHANGE: the terminal asks only for the Tailscale key; the
  registry pull token moves into the setup form (validated live at
  submit — a typo is a field error, not a stalled install). The
  multi-GB image pull moves onto the progress page as its first step;
  the URL appears in ~2 minutes. Unattended path unchanged
  (OPSROOM_PULL_TOKEN / --token-file pulls early, form field hidden).
