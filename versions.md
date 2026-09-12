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

## 2026-09-12 — deploy-v0.2.1

- OPSROOM_TAG: 0.1.1 (unchanged)
- deploy repo: deploy-v0.2.1 (prev: deploy-v0.2.0)
- Hardening of the v0.2.0 flow, found by reading it rather than by
  running it (no fresh-box run has exercised v0.2.0 yet):
  - setup server: a field error used to re-render an EMPTY form, so the
    "a typo is a free retry" promise cost you every other field. Non-secret
    answers now come back; passwords, tokens and keys never do.
  - setup server: the deploy phase shreds answers.json ~20s in, and the
    form was gated on that file — so a refresh (or a second tailnet device)
    mid-install got a blank form, and submitting it started a SECOND
    concurrent deploy. Reproduced against v0.2.0, then gated on the status
    file instead.
  - setup server: admin username and the three S3 fields are checked at
    submit. They were consumed unchecked by the deploy phase, which failed
    minutes later with the form gone and the answers shredded.
  - setup server: pasted whitespace is stripped from the token and the
    other typed fields (a trailing newline read as "the registry rejected
    that token").
  - install.sh: the keycloak-init wait was an unbounded until-loop — the
    one failure the ERR trap cannot catch, and a browser parked on
    "seeding keycloak" forever. Bounded at 15 min, and it now reads the
    exit code instead of proceeding after a non-zero one.
  - install.sh: --fresh left /etc/opsroom/versions behind.
  - install.sh: the deploy-phase docker login hardcoded ghcr.io/algoradev
    where the front half honors $REGISTRY_HOST / $OPSROOM_PULL_USER.
- upgrades.json: the three shipped deploy versions recorded (all
  breaking:false — no entry has moved OPSROOM_TAG yet).
- 2026-09-12 — THE RELEASE GATE (product board 150, D9; reports 153/154):
  product images built after b88df95 REFUSE to start in production unless
  SESSION_TOKEN_PRIVATE_KEY_B64, MCP_BEARER and OPSROOM_BACKUP_DEST are
  each set (or declared `none`). The installer never minted the signing
  key, so every install would have failed at first boot on the next tag.
  - install.sh: mints the RSA-2048 signing key (base64 PEM, once per
    instance) into a fresh .env; `--upgrade` and the resume path append
    the two mintable values to an older .env and STOP on a missing backup
    destination. Proven here: the minted key loads through asunset_core's
    exact code path and survives compose's .env parsing byte-for-byte.
  - install.sh: the doctor is gone (D9 — "there is no doctor"). Final
    checks and the `--upgrade` result are a three-part gate: compose
    health, the api's `/healthz` (404 on 0.1.1 images is recorded as
    "absent", not hidden), and the realm check. The version is recorded
    AFTER the gate passes. An api that refuses to boot has its first log
    lines copied into the install log the browser points at.
  - setup form: one new field, the domain package (`OPSROOM_DISTRO`,
    board 150 D1), default healthcare@0.1, `none` for a blank instance.
  - NOT in this release: the object-store credentials (board 150 D3/D7)
    — only OPSROOM_OBJECT_STORE_BASE exists on the product's main; the
    form grows those fields when the G5 names land there.
  - The customer compose is UNCHANGED (still the 0.1.1 shape with the
    doctor/renderer services present). It is regenerated once, from a
    product main that has G4, for the release that moves OPSROOM_TAG.
- tests/proof.sh: what the gate work proves without a fresh box (13
  checks; needs docker + python3-cryptography).
