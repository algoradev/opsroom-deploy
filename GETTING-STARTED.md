# Getting started with OpsRoom

This is everything you need to stand up your own OpsRoom instance. It
takes one command on a server, one form in your browser, and about
fifteen minutes — most of it unattended.

## What you need before you start

1. **A server.** A fresh Ubuntu 24.04 (or Debian 12) machine with root
   access — any cloud provider works. Recommended: 2 CPU, 8 GB RAM,
   40 GB disk.
2. **A Tailscale account and one auth key.** OpsRoom is served only on
   your private tailnet — that is its front-door security; it is never
   exposed to the public internet. Create a key at
   `login.tailscale.com/admin/settings/keys` (single-use is fine; it is
   consumed when the server joins).
3. **Your registry pull token**, provided by your OpsRoom vendor. It is
   read-only and only lets the server download the product images.
4. *(Recommended)* **S3-compatible storage for backups** — a bucket,
   its endpoint URL, and an access key pair (for example Cloudflare
   R2). The setup form asks for these; you can add them later, but an
   instance without backups is a promise to your future self you may
   regret.
5. **Outbound network access** from the server to: `ghcr.io`,
   `docker.io`, `quay.io` (images), `tailscale.com`, `github.com`, and
   your backup endpoint. If your server sits behind an egress firewall,
   allow these first — otherwise step 1 fails partway with no warning.

## Step 1 — one command on the server

SSH into the server and run:

```
curl -fsSL https://raw.githubusercontent.com/algoradev/opsroom-deploy/main/install.sh | sudo bash
```

It asks for **one thing — your Tailscale key** — installs its tools,
joins your tailnet, and prints a URL, then exits (about two minutes).
The pull token goes into the browser form in step 2, where a typo is a
field error instead of a stalled install. **You are done with the
terminal** — you can close the SSH session; nothing that follows
depends on it.

*Unattended / cloud-init:* provide both credentials up front and nothing
prompts:

```
sudo OPSROOM_PULL_TOKEN=... TS_AUTHKEY=tskey-auth-... bash install.sh
```

(or `--token-file /path` to keep the token out of shell history).

## Step 2 — one form in your browser

Open the printed URL from any device on your tailnet. The form asks
for, once:

- **Your administrator account** — the username and password YOU choose.
  There are no default accounts and no seeded users; this is the only
  way in.
- **Backup storage** — the S3 details from above.
- **Recovery keys** — leave both on *Generate* for a first instance.
  They are shown to you **once**, at the end: put them in a password
  manager immediately. The rule is *two places, or nothing* — an
  instance whose keys exist in one place is one accident away from
  unrecoverable backups.

Submit, and watch: the page shows install progress live, then drops you
onto your instance's login page by itself. Log in with the
administrator account you just created — the first screen asks you to
name your organization, and then you are in your workspace.

## What you end up with

Your own OpsRoom, reachable at `https://<name>.<your-tailnet>.ts.net/`
from any device on your tailnet, running entirely on your server from
signed, versioned images. Sessions last 8 hours; backups run to your
bucket, encrypted with the key only you hold.

## Later

- **Upgrading:** on the server, `cd ~opsroom/opsroom-deploy && sudo bash
  install.sh --upgrade`. Snapshots are taken before anything migrates;
  see `README.md` for the rollback story.
- **Starting over** (test boxes): `sudo bash install.sh --fresh`.
- Everything else — requirements in detail, where your data lives,
  limits, disaster recovery — is in `README.md` beside this file.

## If something goes wrong

The install log lives at `/var/log/opsroom-install.log` on the server,
and the progress page names the exact step that failed. Send both to
your vendor — the step text is designed to be the diagnosis.
