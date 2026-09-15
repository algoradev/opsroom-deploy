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

## 2026-09-15 — deploy-v0.2.2

- OPSROOM_TAG: 0.1.1 (unchanged — still no image release past b88df95)
- deploy repo: deploy-v0.2.2 (prev: deploy-v0.2.1)

**Backups became restorable.** Three gaps, each of which made a backup that
reported success and could not be used:

- **The roles file.** `pg_dump` of one database carries every `GRANT … TO
  web_anon` and no `CREATE ROLE`, so on a fresh cluster the replay stops and
  no rows land. Reproduced on this machine and fixed:
  `tests/proof-restore-order.sh` replays a dump on two fresh clusters, one
  without the roles (fails, restores nothing) and one with them loaded first
  (clean under ON_ERROR_STOP, rows and schema revision read back).
  `backup.sh` ships `product-roles.sql.gpg`.
- **The sealed configuration (`env.age`).** The databases only accept the
  passwords that created them, and those live only in `.env` on the host —
  in no artifact. So a backup without it restored data that nothing could
  connect to. `.env` is now sealed to the instance's **age** key and shipped
  beside the dumps. Not the backup passphrase: the age key is the one secret
  deliberately absent from the backup, so the bucket alone is never enough.
- **The drill never replayed the product dump.** It decrypted the one
  artifact holding rows you cannot rebuild and stopped, so a PASS said
  nothing about the product database. It now loads roles, replays under
  ON_ERROR_STOP, reads back `alembic_version`, `registry.sources` and
  `registry.projects`, and proves the seal opens with this box's key.

A production backup with no destination used to print "Nothing to do." and
exit 0 — a nightly timer reporting success on an instance with no backups.
It now refuses, with the cure. The destination holds **7** objects.

**`install.sh --restore` exists.** Same front half as an install (tools,
tailnet, orchestration, browser), a different form: which backup, the
passphrase, the age key. Then, in this order — configuration first, host
URLs repointed at the new machine, image tag pinned to what the backup was
taken with, **databases only** up before the replay (Keycloak and OpenFGA
initialise their own schemas the moment they boot), roles before the product
dump, and the restored rows READ BACK before anything is handed over. It
refuses over a living instance. `opsroom-init` is not run: the organization
came back with the data.

**`MCP_BEARER=none` is refused by the installer (D13).** The MCP server
reads that variable *as* the shared secret, so `none` installs a live door
key whose value is the word "none". deploy-v0.2.1's `.env.example` told
operators `none` was valid for all three boot values; it was wrong, and a
hand-edited `.env` that took the advice is now caught before boot.

**File storage is asked for (D3/D7):** the five `OPSROOM_OBJECT_STORE_*`
values, as a second bucket with its own token. The form refuses a shared
bucket or a shared token — backups are pruned on a timer and uploaded files
are not.

**The configuration pre-check runs through the image** (`python -m
opsroom.config check --process`), on install, restore and upgrade. The
customer host has no venv, so the image is the only thing carrying the
manifest, and `--process` asks only the rows a container can answer. On the
upgrade it runs **after the pull** and before anything is recreated, so a
release that adds a required row stops the upgrade with the instance still
up. An image with no manifest reports "cannot pre-check" — never a pass.

- The doctor gate in `--upgrade` was already the compose-health + `/healthz`
  + realm triple (deploy-v0.2.1); the handover is now one shared function
  instead of two copies of an order that was measured twice.
- tests/proof.sh: 48 checks. tests/proof-restore-order.sh: 11 more.
- NOT proven here: a fresh-box run of the restore, which needs a real
  backup and a real box. That is the plan's step 8b, and it is the one that
  turns this from built to true.

## 2026-09-15 — deploy-v0.2.3

- OPSROOM_TAG: 0.1.1 (unchanged)
- deploy repo: deploy-v0.2.3 (prev: deploy-v0.2.2)

**A one-line release blocker in v0.2.1 and v0.2.2, found by reading Juniper's
addendum and then measuring it.** caddy's healthcheck in the generated compose
spidered `http://localhost:2019/config/`. In the caddy alpine image
`localhost` resolves to `::1` only (`getent hosts localhost` → `::1`), and the
admin endpoint binds `127.0.0.1` — so the probe is refused on every tick and
caddy is `unhealthy` forever. Verified directly in `caddy:2.8-alpine`:
numeric OK, name REFUSED.

Harmless before v0.2.1, because nothing `depends_on` caddy. **Fatal from
v0.2.1**, because `gate()` requires every healthchecked service to be healthy
— so the final check of every fresh install, and every `--upgrade`, would
have failed with a perfectly good instance behind it. Neither tag had been
run on a fresh box, which is exactly how a false red survives to a release.

- `docker-compose.yml` is a GENERATED file and this is a hand patch, taken
  deliberately: the product's `compose.product.yml` already carries the
  numeric form, so this converges with the regeneration rather than diverging
  from it. The regeneration (deploy-v0.3.0) will emit the same line.
- `tests/proof.sh` section 18 asserts no shipped healthcheck probes
  `http://localhost`, so the regeneration cannot bring the name back.
- The lesson, recorded because it generalises: a gate that makes every red
  fatal inherits every false red that was previously cosmetic. Turning a
  report into a gate means auditing what it reports first.

## 2026-09-15 — deploy-v0.2.4

- OPSROOM_TAG: 0.1.1 (unchanged)
- deploy repo: deploy-v0.2.4 (prev: deploy-v0.2.3)

**`OPSROOM_BACKUP_DEST=none` meant two different things in two places, and this
file was recommending the bad one.** The API's config accepts `none` as a
declared choice. `backup/backup.sh` REFUSES it on a production instance — and
every instance installed from this repo is production. So an operator who took
`.env.example`'s advice got an instance that booted normally and whose every
scheduled backup refused: success by doing nothing, which is the failure the
refusal was added to prevent.

- `install.sh` and `install.sh --upgrade` now stop on that combination and say
  why, so the installer and the backup runner agree.
- `.env.example` no longer offers the word. It says what `none` is for (dev)
  and that this path stops on it.
- `none` on a non-production instance is still accepted, unchanged.

Found by reading the product repo's own correction of the same invitation
(`6dd9e18`, 2026-09-15: "`none` (a declared choice; doctor skips)" — nothing
skips, and backup.sh refuses). The customer-facing copy of a wrong sentence
needs finding separately from the one that was fixed.

- tests/proof.sh: 54 checks.
