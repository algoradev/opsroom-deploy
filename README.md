# OpsRoom — deploy

The orchestration for a self-hosted OpsRoom instance. **This repo is
public and contains no secrets**; the product arrives as pulled, signed
container images from a private registry, pinned by `release.env`.
Nothing is ever built on your box.

You need two credentials, both from your OpsRoom vendor / your own infra:
a **registry pull token** (read-only; entered in the setup form) and a
**Tailscale auth key** (single-use; the instance is served tailnet-only —
that is its front-door security).

## Install

On a fresh Ubuntu/Debian box (2 CPU / 8 GB / 40 GB disk recommended —
Keycloak sets the floor):

```
curl -fsSL https://raw.githubusercontent.com/algoradev/opsroom-deploy/main/install.sh | sudo bash
```

It asks for **one thing — the Tailscale key** — prints a URL, and
exits (~2 minutes). The pull token goes into the form, validated live at
submit; the product download runs as the install's first progress step. Open the URL in a browser on your tailnet, fill the setup form
(your admin account, backup credentials, recovery keys), and watch it
install — the page drops you into OpsRoom's login when it is done. The
install does not run in your terminal; a dropped SSH connection cannot
kill it.

Unattended (cloud-init):

```
sudo OPSROOM_PULL_TOKEN=... TS_AUTHKEY=tskey-auth-... bash install.sh
```

The token can also come from a file: `--token-file /path` (no shell
history, survives sudo's env filtering).

### Egress the box needs

`ghcr.io` (product images) · `docker.io` and `quay.io` (infra images) ·
`tailscale.com` · `github.com` (this repo) · your S3 backup endpoint.

## Upgrade

```
cd ~opsroom/opsroom-deploy && sudo bash install.sh --upgrade
```

Order is deliberate: registry auth is validated first; a **database
snapshot is taken before anything migrates**; `git pull` moves the
orchestration and the tracked pin (`release.env`); images pull **to
completion** before any service is touched; then a three-part gate
(every compose healthcheck healthy, the api's own `/healthz`, the realm
check) decides whether the new version is **recorded** — a red gate
leaves `/etc/opsroom/versions` at the previous pin. Before pulling, the
upgrade also makes sure `.env` carries the configuration newer images
refuse to boot without (it mints what it can; a missing backup
destination stops it, since that is your decision).
`upgrades.json` entries marked breaking stop for your confirmation.

## Rollback

Two tiers — which applies is in `versions.md` / `upgrades.json`:

- **No migration in the release:** set `OPSROOM_TAG=<previous>` in your
  `.env` (it overrides the tracked pin; the installer warns about the
  override until you remove it), then `docker compose --env-file
  release.env --env-file .env pull && ... up -d`.
- **Migration-bearing release:** restore the pre-upgrade snapshot from
  `backups/` **and** pin the previous tag. Data written after the
  upgrade is lost — that is what the snapshot boundary means.

Old images stay on the box after upgrades (only dangling layers are
pruned) — rollback never depends on the registry being reachable.

## Backups & restore

The setup form configures S3-compatible backups (encrypted with an age
key generated — or restored — during setup and **shown once**: put it in
a password manager. Two places, or nothing.) `backup/backup.sh` runs the
backup; `backup/restore-drill.sh <stamp>` proves a backup actually
restores — run the drill on a schedule you'd bet the company on.

Disaster recovery today: fresh box → run the installer → choose
**"Restore an existing age key"** in the form → restore the latest
snapshot with `backup/restore-drill.sh`. (`install.sh --restore` as a
single command is planned, not yet built.)

## Re-runs and wiping

The installer is check-then-act: a half-done box resumes or refuses
loudly — it never regenerates secrets over an initialized database, and
it **never deletes an age key on its own** (destroying the only
decryption key is how instances die). To wipe deliberately:

```
sudo bash install.sh --fresh                    # containers, volumes, config
sudo bash install.sh --fresh --and-the-age-key  # ...and the key. Only if no backup needs it.
```

## Where your data lives

Named volumes, project `opsroom`: `opsroom_postgres-data` (identity:
Keycloak/OpenFGA/audit), `opsroom_opsroom-pg-data` (product DB),
`opsroom_opsroom_home` (instance home: methodology, uploads),
`opsroom_caddy-data`, `opsroom_keycloak-providers`,
`opsroom_keycloak-themes`. Snapshot the first three; the rest rebuild.

## Limits, stated

One instance per box (fixed project name and ports — structural).
Air-gapped installs are out of scope for now (the images require
registry egress). During the setup window, anyone on your tailnet can
reach the form — install from an ACL-restricted node if your tailnet is
shared.

## Files

`install.sh` — install / `--upgrade` / `--fresh`. `docker-compose.yml` —
the whole stack, images only (generated in the product repo; do not
hand-edit). `release.env` — the tracked product pin. `.env.example` —
every knob, inert. `config/` — everything the stack mounts. `setup/` —
the browser setup form. `bin/` — realm doctor + session-lifespan tool.
`backup/` — backup + restore drill. `versions.md` / `upgrades.json` —
the upgrade contract.
