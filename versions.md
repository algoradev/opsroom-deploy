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
