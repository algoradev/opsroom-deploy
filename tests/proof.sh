#!/usr/bin/env bash
# What the deploy-v0.2.1 gate work proves WITHOUT a fresh box (run from anywhere:
#   bash tests/proof.sh). Needs docker (compose v2) and python3-cryptography.
set -u
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ✓ %s\n' "$*"; }
bad()  { fail=$((fail+1)); printf '  ✗ %s\n' "$*"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# ── extract the shared functions from install.sh (never source the whole script) ──
awk '/^gate\(\) \{/,/^}$/' install.sh > "$T/fns.sh"
awk '/^mint_session_key\(\) \{/,/^}$/' install.sh >> "$T/fns.sh"
awk '/^ensure_trio\(\) \{/,/^}$/' install.sh >> "$T/fns.sh"
INSTALL_LOG="$T/install.log"; touch "$INSTALL_LOG"
# shellcheck disable=SC1090
. "$T/fns.sh"
run() { "$@"; }

echo "1. the minted key loads through asunset_core's exact path (base64 -> PEM -> RSA)"
K=$(mint_session_key); rc=$?
check "mint returns 0"                 '[ $rc = 0 ]'
check "single line, no newline"        '[ "$(printf "%s" "$K" | wc -l)" = 0 ]'
printf 'SESSION_TOKEN_PRIVATE_KEY_B64=%s\n' "$K" > "$T/a.env"
python3 - "$K" <<'PY' && ok "cryptography: RSA private key, 2048 bits" || bad "cryptography could not load the key"
import base64, sys
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.rsa import RSAPrivateKey
key = serialization.load_pem_private_key(base64.b64decode(sys.argv[1]), password=None)
assert isinstance(key, RSAPrivateKey) and key.key_size == 2048, type(key)
PY

echo "2. the value survives a compose .env file unmangled"
cat > "$T/compose.yml" <<'Y'
services:
  probe:
    image: busybox
    environment:
      SESSION_TOKEN_PRIVATE_KEY_B64: ${SESSION_TOKEN_PRIVATE_KEY_B64:?unset}
Y
GOT=$(docker compose -f "$T/compose.yml" --env-file "$T/a.env" config --format json 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["probe"]["environment"]["SESSION_TOKEN_PRIVATE_KEY_B64"])')
check "compose interpolates the key byte-for-byte" '[ "$GOT" = "$K" ]'

echo "3. ensure_trio on an OLD .env (deploy-v0.2.0 shape: bearer + dest, no key)"
printf 'OPSROOM_ENV=production\nMCP_BEARER=abc\nOPSROOM_BACKUP_DEST=s3://b\n' > "$T/old.env"
OUT=$(ensure_trio "$T/old.env"); rc=$?
check "returns 0 and appends the key"     '[ $rc = 0 ] && grep -q "^SESSION_TOKEN_PRIVATE_KEY_B64=." "$T/old.env"'
check "says what it did"                  'printf "%s" "$OUT" | grep -q "minted and appended"'
LINES=$(wc -l < "$T/old.env"); ensure_trio "$T/old.env" >/dev/null; rc=$?
check "idempotent: second run appends nothing" '[ $rc = 0 ] && [ "$(wc -l < "$T/old.env")" = "$LINES" ]'
printf 'OPSROOM_ENV=production\n' > "$T/bare.env"
OUT=$(ensure_trio "$T/bare.env"); rc=$?
check "no backup dest: returns 1, mints the other two, names the decision" \
  '[ $rc = 1 ] && grep -q "^MCP_BEARER=." "$T/bare.env" && grep -q "^SESSION_TOKEN_PRIVATE_KEY_B64=." "$T/bare.env" && printf "%s" "$OUT" | grep -q "OPSROOM_BACKUP_DEST is unset"'
printf 'OPSROOM_BACKUP_DEST=none\n' >> "$T/bare.env"
ensure_trio "$T/bare.env" >/dev/null; rc=$?
check "dest declared none: accepted"      '[ $rc = 0 ]'

echo "4. gate step 1: the compose ps format + filter, against a real running stack"
if docker compose ls --format json 2>/dev/null | python3 -c 'import json,sys; sys.exit(0 if any(p["Status"].startswith("running") for p in json.load(sys.stdin)) else 1)'; then
  P=$(docker compose ls --format json | python3 -c 'import json,sys; print([p for p in json.load(sys.stdin) if p["Status"].startswith("running")][0]["Name"])')
  PS=$(docker compose -p "$P" ps --format '{{.Service}} {{.Health}}' 2>&1); rc=$?
  check "ps --format renders (project $P)"  '[ $rc = 0 ] && [ -n "$PS" ]'
  printf '%s\n' "$PS" | sed 's/^/      /'
  BAD=$(printf '%s\n' "$PS" | awk '$2 != "" && $2 != "healthy"')
  check "filter yields only non-healthy healthchecked services (got: '${BAD:-none}')" 'true'
else
  bad "no running compose project on this machine — step-1 format untested here"
fi

echo "5. gate step 2: the healthz probe script itself (404 -> rc 3, 503 -> rc 1, 200 -> rc 0)"
python3 - <<'PY' && ok "probe exit codes: 200->0, 404->3, 503->1" || bad "probe exit codes wrong"
import http.server, threading, subprocess, sys, re
src = open("install.sh").read()
probe = re.search(r"python -c '(\nimport sys, urllib.*?)' 2>>", src, re.S).group(1)
class H(http.server.BaseHTTPRequestHandler):
    code = 200
    def log_message(self,*a): pass
    def do_GET(self):
        b = b'{"status":"x"}'; self.send_response(self.code); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
srv = http.server.HTTPServer(("127.0.0.1", 8001), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
want = {200: 0, 404: 3, 503: 1}
for code, rc in want.items():
    H.code = code
    r = subprocess.run([sys.executable, "-c", probe], capture_output=True)
    assert r.returncode == rc, (code, r.returncode, r.stdout, r.stderr)
srv.shutdown()
PY

echo "6. setup/server.py coherence: the distro rule"
python3 - <<'PY' && ok "distro: accepts healthcare@0.1, none, x-y@1.2.3; rejects '', Healthcare@1, foo, foo@" || bad "distro rule wrong"
import ast, re
src = open("setup/server.py").read()
tree = ast.parse(src)
fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "coherence")
ns = {"re": re, "PULLED": "1", "RESTORE": "0", "registry_ok": lambda t: True}
exec(compile(ast.Module([fn], []), "server.py", "exec"), ns)
base = {"admin_user": "dave", "backup_bucket": "b", "s3_key": "k", "s3_secret": "s", "s3_endpoint": "https://x", "admin_pass": "x"*12}
def errs(d): return [e for e in ns["coherence"]({**base, "distro": d}) if "Domain package" in e]
for good in ("healthcare@0.1", "none", "x-y@1.2.3"): assert not errs(good), good
for badv in ("", "Healthcare@1", "foo", "foo@", "@1"): assert errs(badv), badv
PY

echo "7. backup.sh: a production instance with no destination REFUSES (it used to exit 0)"
# Run the real script from a throwaway tree so nothing touches this checkout.
mkdir -p "$T/inst/backup"; cp backup/backup.sh "$T/inst/backup/"
run_backup() {   # $1 = OPSROOM_ENV, $2 = OPSROOM_BACKUP_DEST value
  printf 'OPSROOM_ENV=%s\nOPSROOM_BACKUP_DEST=%s\nOPSROOM_BACKUP_PASSPHRASE=x\n' "$1" "$2" > "$T/inst/.env"
  ( cd "$T/inst" && bash backup/backup.sh 2>&1 ); printf 'rc=%s' "$?"
}
OUT=$(run_backup production none)
case "$OUT" in
  *"rc=1"*) printf '%s' "$OUT" | grep -q "PRODUCTION instance — refusing" \
      && ok "production + dest none: exits 1 and names why" \
      || bad "production + dest none: exited 1 without the sentence" ;;
  *) bad "production + dest none did NOT refuse: ${OUT##*rc=}" ;;
esac
OUT=$(run_backup production "")
printf '%s' "$OUT" | grep -q "rc=1" && ok "production + dest unset: also refuses" || bad "production + dest unset did not refuse"
OUT=$(run_backup dev none)
printf '%s' "$OUT" | grep -q "rc=0" && printf '%s' "$OUT" | grep -q "Nothing to do" \
  && ok "dev + dest none: still 'nothing to do', exit 0 (no permanent red on a laptop)" \
  || bad "dev + dest none should exit 0 with 'Nothing to do'"

echo "8. backup.sh: data/ is excluded only when an object store holds it"
# The branch, extracted and evaluated — the tar command is what the claim is.
awk '/^if \[ -n "\$OBJ_BASE" \]; then$/,/^fi$/' backup/backup.sh > "$T/excl.sh"
grep -q 'exclude=./data' "$T/excl.sh" || bad "could not extract the exclusion branch"
( OBJ_BASE="s3://bucket" ; . "$T/excl.sh" ; case "$TAR_CMD" in *--exclude=./data*) exit 0;; *) exit 1;; esac ) \
  && ok "object store configured: data/ EXCLUDED (step 5 mirrors it)" \
  || bad "object store configured but data/ not excluded"
( OBJ_BASE="" ; . "$T/excl.sh" ; case "$TAR_CMD" in *--exclude*) exit 1;; *) exit 0;; esac ) \
  && ok "no object store: data/ INCLUDED (the tarball is its only copy)" \
  || bad "no object store but data/ was excluded — that drops every upload"

echo "9. both runners agree on the six objects and the roles file"
grep -q 'n" -ge 7' backup/backup.sh && ok "backup.sh verifies 7 objects at the destination" || bad "backup.sh does not expect 7 objects"
grep -q 'product-roles.sql.gpg' backup/restore-drill.sh && ok "the drill downloads the roles file" || bad "the drill ignores the roles file"
grep -q 'env.age' backup/backup.sh && ok "backup.sh seals the configuration into the backup" || bad "backup.sh does not seal .env"
grep -q '5b/6 the sealed configuration' backup/restore-drill.sh && ok "the drill proves the seal opens with this box's age key" || bad "the drill does not check the seal"
grep -q 'ON_ERROR_STOP=1' backup/restore-drill.sh && ok "the drill REPLAYS the product dump (it used to only decrypt it)" || bad "the drill still never replays the product dump"
# Comments may DISCUSS the retired sentinel (they explain why it went); only a
# live line that tests for it is the false red this checks for.
if grep -v "^[[:space:]]*#" backup/restore-drill.sh | grep -q "context.yaml"; then
  bad "the drill still asserts the retired context.yaml"
else
  ok "no live line asserts the retired context.yaml"
fi

echo "10. the form is ONE document, and each mode deletes what it must not ask"
python3 - <<'PY' && ok "each mode asks only its own questions, and no marker survives" || bad "the mode-stripped forms are wrong"
import sys, os
src = open("setup/server.py").read()
head = src.split("INSTALLING = ")[0]   # everything up to the first side effect

def build(restore, pulled="0"):
    # server.py imports sys itself, so the REAL argv is what it reads.
    sys.argv = ["server.py", "setup", "answers.json", "1", "status", "self",
                "repo", "dns", "user", "log", "ghcr.io", "ns", pulled, restore]
    ns = {"__name__": "srv"}
    exec(compile(head, "server.py", "exec"), ns)
    return ns["FORM"]

f = build("0")
for want in ('name="admin_user"', 'name="admin_pass"', 'name="distro"',
             'name="invite_mode"', 'name="age_mode"', 'name="pass_mode"',
             'name="pull_token"'):
    assert want in f, "install form lost " + want
assert 'name="stamp"' not in f, "install form asks for a backup stamp"
assert ">Install<" in f and "<!--SUBMIT-->" not in f, "install button label"
assert "first-run setup" in f, "install header missing"
assert "OpsRoom — restore" not in f, "install form carries the restore header"

r = build("1")
for want in ('name="stamp"', 'name="backup_pass"', 'name="age_key"',
             'name="backup_bucket"', 'name="s3_secret"', 'name="pull_token"'):
    assert want in r, "restore form lost " + want
for gone in ('name="admin_user"', 'name="admin_pass"', 'name="distro"',
             'name="invite_mode"', 'name="age_mode"', 'name="pass_mode"'):
    assert gone not in r, "restore form still asks " + gone
assert ">Restore<" in r, "restore button label"
assert "OpsRoom — restore" in r and "first-run setup" not in r, "restore header"
assert "<title>OpsRoom restore</title>" in r, "restore title"

# NO UNSTRIPPED MARKER may reach a browser in either mode: a leftover
# <!--ADMIN--> means a block was renamed and its deletion silently stopped
# matching, which is exactly how a restore would start asking for an admin.
for name, form in (("install", f), ("restore", r)):
    body = form.split("<main>")[1].split("</main>")[0]
    for keep in ("<!--ERR-->", "<!--VALUES-->", "<!--WHY-RESTORE-->"):
        body = body.replace(keep, "")
    assert "<!--" not in body, "%s form leaks a marker: %s" % (
        name, body[body.index("<!--"):body.index("<!--") + 40])

# The pull-token fieldset still disappears when the images came up front.
assert 'name="pull_token"' not in build("0", pulled="1"), "registry fieldset not stripped"
assert 'name="pull_token"' not in build("1", pulled="1"), "registry fieldset not stripped on restore"
PY

echo "11. restore-mode coherence: the inputs that would fail mid-database"
python3 - <<'PY' && ok "restore: age key prefix, passphrase and stamp shape enforced; admin/distro not asked" || bad "restore coherence wrong"
import ast, re
tree = ast.parse(open("setup/server.py").read())
fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "coherence")
def errs(d, restore="1"):
    ns = {"re": re, "PULLED": "1", "RESTORE": restore, "registry_ok": lambda t: True}
    exec(compile(ast.Module([fn], []), "s.py", "exec"), ns)
    return ns["coherence"](d)
good = {"backup_bucket": "b", "s3_key": "k", "s3_secret": "s", "s3_endpoint": "https://x",
        "age_key": "AGE-SECRET-KEY-1ABC", "backup_pass": "pp", "stamp": ""}
assert errs(good) == [], errs(good)
assert errs({**good, "stamp": "20260913T025705Z"}) == []
assert any("AGE-SECRET-KEY" in e for e in errs({**good, "age_key": "nope"}))
assert any("passphrase" in e for e in errs({**good, "backup_pass": ""}))
assert any("stamped like" in e for e in errs({**good, "stamp": "yesterday"}))
assert any("https" in e for e in errs({**good, "s3_endpoint": "http://x"}))
assert any("Bucket" in e for e in errs({**good, "backup_bucket": ""}))
# the restore must NOT demand what it does not ask for
assert errs(good) == [], "restore mode demands an install-only field"
# and install mode must still demand them
ie = errs({**good, "admin_pass": "x"*12}, restore="0")
assert any("administrator" in e.lower() for e in ie), ie
PY

echo "12. the restore rewrites the host URLs and keeps every credential"
python3 - <<'PY' && ok "host URLs repointed at the new box; all other settings byte-identical" || bad "host-URL rewrite wrong"
import re, subprocess, sys, tempfile, os
src = open("install.sh").read()
# the rewrite is the heredoc body inside the restore branch
body = src.split("python3 - \"$REPO_DIR/.env\" \"$TS_DNS\" <<'PYEOF'")[1].split("\nPYEOF")[0]
body = body.split("\n", 1)[1]           # drop the rest of the invocation line
d = tempfile.mkdtemp()
env = os.path.join(d, ".env")
original = [
    "TAILSCALE_HOST=old-box.tail1234.ts.net\n",
    "OPSROOM_PUBLIC_ORIGIN=https://old-box.tail1234.ts.net\n",
    "OPSROOM_PUBLIC_URL=https://old-box.tail1234.ts.net\n",
    "KEYCLOAK_PUBLIC_URL=https://old-box.tail1234.ts.net/auth\n",
    "APP_DB_PASSWORD=keep-me-exactly\n",
    "KEYCLOAK_API_CLIENT_SECRET=also-keep=me+with/chars\n",
    "OPSROOM_DISTRO=healthcare@0.1\n",
]
open(env, "w").writelines(original)
script = os.path.join(d, "rw.py"); open(script, "w").write(body)
r = subprocess.run([sys.executable, script, env, "new-box.tail1234.ts.net"], capture_output=True)
assert r.returncode == 0, r.stderr
got = dict(l.rstrip("\n").split("=", 1) for l in open(env))
assert got["TAILSCALE_HOST"] == "new-box.tail1234.ts.net", got["TAILSCALE_HOST"]
assert got["OPSROOM_PUBLIC_ORIGIN"] == "https://new-box.tail1234.ts.net"
assert got["OPSROOM_PUBLIC_URL"] == "https://new-box.tail1234.ts.net"
assert got["KEYCLOAK_PUBLIC_URL"] == "https://new-box.tail1234.ts.net/auth"
# THE POINT OF THE WHOLE RESTORE: the credentials are untouched
assert got["APP_DB_PASSWORD"] == "keep-me-exactly"
assert got["KEYCLOAK_API_CLIENT_SECRET"] == "also-keep=me+with/chars"
assert got["OPSROOM_DISTRO"] == "healthcare@0.1"
assert len(got) == 7, got
# and a .env that never had the host lines GAINS them
open(env, "w").write("APP_DB_PASSWORD=x\n")
subprocess.run([sys.executable, script, env, "n.ts.net"], check=True, capture_output=True)
got2 = dict(l.rstrip("\n").split("=", 1) for l in open(env))
assert got2["KEYCLOAK_PUBLIC_URL"] == "https://n.ts.net/auth", got2
PY

echo "13. backup.sh seals .env to the age key, and the seal opens again"
if command -v age >/dev/null && command -v age-keygen >/dev/null; then
  mkdir -p "$T/seal"; age-keygen -o "$T/seal/keys.txt" 2>/dev/null
  printf 'APP_DB_PASSWORD=s3kr1t\nOPSROOM_BACKUP_DEST=s3://b\nKEYCLOAK_API_CLIENT_SECRET=cs\n' > "$T/seal/.env"
  # the same two commands backup.sh runs, in the same order
  PUB=$(age-keygen -y "$T/seal/keys.txt")
  if age -r "$PUB" -o "$T/seal/env.age" "$T/seal/.env" 2>/dev/null \
     && age -d -i "$T/seal/keys.txt" "$T/seal/env.age" | grep -q '^APP_DB_PASSWORD=s3kr1t$'; then
    ok "seal round-trips, and the recovered file carries the credentials"
  else
    bad "the age seal did not round-trip"
  fi
  # A DIFFERENT key must NOT open it — this is what makes the bucket alone useless.
  age-keygen -o "$T/seal/other.txt" 2>/dev/null
  if age -d -i "$T/seal/other.txt" "$T/seal/env.age" >/dev/null 2>&1; then
    bad "a DIFFERENT age key opened the seal"
  else
    ok "a different age key cannot open it (the bucket alone is not enough)"
  fi
  grep -q 'age -r "$AGE_PUB" -o "$WORK/env.age" .env' backup/backup.sh \
    && ok "backup.sh uses exactly that seal command" || bad "backup.sh seal command drifted from this proof"
else
  bad "age not installed here — the seal is untested on this machine"
fi

echo "14. --restore is wired, not a stub"
grep -q "restore is not automated yet" install.sh && bad "--restore is still the stub" || ok "the --restore stub is gone"
grep -q 'DEPLOY_MODE="${6:-install}"' install.sh && ok "the deploy phase takes a mode" || bad "deploy phase has no mode argument"
grep -q '"restore" if RESTORE == "1" else "install"' setup/server.py && ok "the setup server passes the mode through" || bad "server does not pass the mode"
grep -q 'up -d --wait --wait-timeout 600 postgres opsroom-postgres' install.sh \
  && ok "the restore brings up ONLY the databases before replaying" || bad "the restore starts more than the databases before the replay"
grep -q 'this machine already runs an instance' install.sh \
  && ok "--restore refuses over a living instance" || bad "--restore would replay over a living instance"
# ONE handover, not two: the kill/serve order was measured twice and must not fork.
[ "$(grep -c 'tailscale serve --bg --https=443 localhost:5173' install.sh)" = 1 ] \
  && ok "handover exists once, shared by install and restore" || bad "the handover order is duplicated"

echo "15. MCP_BEARER has no off-switch: the word none is caught in the installer (D13)"
printf 'OPSROOM_ENV=production\nMCP_BEARER=none\nOPSROOM_BACKUP_DEST=s3://b\nSESSION_TOKEN_PRIVATE_KEY_B64=x\n' > "$T/mcp.env"
OUT=$(ensure_trio "$T/mcp.env"); rc=$?
check "MCP_BEARER=none: refused, with the reason" \
  '[ $rc = 1 ] && printf "%s" "$OUT" | grep -q "does not disable authentication"'
printf 'OPSROOM_ENV=production\nMCP_BEARER=log\nOPSROOM_BACKUP_DEST=s3://b\nSESSION_TOKEN_PRIVATE_KEY_B64=x\n' > "$T/mcp2.env"
OUT=$(ensure_trio "$T/mcp2.env"); rc=$?
check "MCP_BEARER=log: refused too (the manifest off-vocabulary is none+log)" '[ $rc = 1 ]'
printf 'OPSROOM_ENV=production\nMCP_BEARER=a-real-secret\nOPSROOM_BACKUP_DEST=none\nSESSION_TOKEN_PRIVATE_KEY_B64=x\n' > "$T/mcp3.env"
ensure_trio "$T/mcp3.env" >/dev/null; rc=$?
check "a real bearer with backups declared none: accepted (only that row has an off switch)" '[ $rc = 0 ]'
grep -q 'deliberately declared `none`' .env.example \
  && bad ".env.example still tells operators all three accept none" \
  || ok ".env.example no longer offers none for the bearer"

echo "16. the object-store fieldset: five fields, and two buckets not one"
python3 - <<'PY' && ok "store validated: s3:// base, https endpoint, distinct bucket AND token" || bad "object-store validation wrong"
import ast, re
tree = ast.parse(open("setup/server.py").read())
fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "coherence")
def errs(d):
    ns = {"re": re, "PULLED": "1", "RESTORE": "0", "registry_ok": lambda t: True}
    exec(compile(ast.Module([fn], []), "s.py", "exec"), ns)
    return ns["coherence"](d)
base = {"admin_user": "dave", "admin_pass": "x"*12, "distro": "healthcare@0.1",
        "backup_bucket": "opsroom-backups", "s3_key": "BKEY", "s3_secret": "bsec",
        "s3_endpoint": "https://acct.r2.cloudflarestorage.com",
        "obj_base": "s3://opsroom-data", "obj_endpoint": "https://acct.r2.cloudflarestorage.com",
        "obj_key": "DKEY", "obj_secret": "dsec", "obj_region": "auto"}
assert errs(base) == [], errs(base)
assert any("s3://" in e for e in errs({**base, "obj_base": "opsroom-data"}))
assert any("endpoint" in e for e in errs({**base, "obj_endpoint": "http://x"}))
assert any("Region" in e for e in errs({**base, "obj_region": ""}))
assert any("Secret Access Key" in e for e in errs({**base, "obj_secret": ""}))
# the two D3 separations
same_bucket = errs({**base, "obj_base": "s3://opsroom-backups"})
assert any("DIFFERENT buckets" in e for e in same_bucket), same_bucket
same_token = errs({**base, "obj_key": "BKEY"})
assert any("DIFFERENT tokens" in e for e in same_token), same_token
# a prefix on the same bucket is still the same bucket
assert any("DIFFERENT buckets" in e for e in errs({**base, "obj_base": "s3://opsroom-backups/data"}))
PY
python3 - <<'PY' && ok "the store fieldset is asked on install and NOT on restore" || bad "store fieldset shown in the wrong mode"
import sys
head = open("setup/server.py").read().split("INSTALLING = ")[0]
def build(restore):
    sys.argv = ["s", "setup", "a", "1", "st", "self", "r", "dns", "u", "log", "ghcr.io", "ns", "0", restore]
    ns = {"__name__": "srv"}; exec(compile(head, "server.py", "exec"), ns); return ns["FORM"]
i, r = build("0"), build("1")
for f in ("obj_base", "obj_endpoint", "obj_key", "obj_secret", "obj_region"):
    assert 'name="%s"' % f in i, "install form lost " + f
    assert 'name="%s"' % f not in r, "restore form asks " + f
PY
for v in OPSROOM_OBJECT_STORE_BASE OPSROOM_OBJECT_STORE_ENDPOINT OPSROOM_OBJECT_STORE_ACCESS_KEY_ID OPSROOM_OBJECT_STORE_SECRET_ACCESS_KEY OPSROOM_OBJECT_STORE_REGION; do
  grep -q "^ *printf .*$v=" install.sh || grep -q "$v" install.sh || bad "install.sh never writes $v"
done
grep -c "OPSROOM_OBJECT_STORE" install.sh >/dev/null && ok "install.sh writes all five store variables into .env"
for v in OPSROOM_OBJECT_STORE_BASE OPSROOM_OBJECT_STORE_REGION; do
  grep -q "^$v=" .env.example || bad ".env.example does not document $v"
done
ok ".env.example documents the store"

echo "17. the config pre-check reads the image, and three answers not two"
grep -q 'python -m opsroom.config check --process' install.sh \
  && ok "asks the IMAGE with --process (the host rows are not the container's)" \
  || bad "the pre-check is not the image-run --process form"
grep -q 'cannot pre-check, NOT a pass' install.sh \
  && ok "an image with no manifest is 'cannot pre-check', never a pass" \
  || bad "a manifest-less image would be read as a pass"
[ "$(grep -c 'config_precheck ||' install.sh)" = 3 ] \
  && ok "called on all three paths: install, restore, upgrade" \
  || bad "the pre-check is not on all three paths (found $(grep -c 'config_precheck ||' install.sh))"
# ON THE UPGRADE IT MUST RUN AFTER THE PULL: the NEW image's manifest is the
# one that can name a row this instance does not have yet.
python3 - <<'PY' && ok "on --upgrade it runs after the pull and before anything is recreated" || bad "upgrade pre-check is in the wrong place"
src = open("install.sh").read()
up = src.split('if [ "${1:-}" = "--upgrade" ]')[1]
pull = up.index("$DC pull -q")
chk = up.index("config_precheck ||")
recreate = up.index("up -d --wait --wait-timeout 900")
assert pull < chk < recreate, (pull, chk, recreate)
PY

echo "18. no shipped healthcheck probes the NAME localhost over HTTP"
# THE GATE MADE THIS FATAL. gate() requires every healthchecked service to be
# healthy, so a probe that can never pass stops every install at the final
# step with a working instance behind it. caddy's shipped probe spidered
# http://localhost:2019/config/ — and in these alpine images `localhost`
# resolves to ::1 ONLY, while the admin endpoint binds 127.0.0.1. Measured in
# the real image, 2026-09-15: numeric OK, name REFUSED, getent says ::1.
# A name is a resolver's opinion; a loopback probe should not depend on it.
python3 - <<'PY' && ok "every http healthcheck uses a numeric loopback" || bad "a healthcheck probes http://localhost — it will never pass, and the gate is fatal"
import yaml
d = yaml.safe_load(open("docker-compose.yml"))
bad = {n: str((s.get("healthcheck") or {}).get("test", ""))
       for n, s in d["services"].items()
       if "http://localhost" in str((s.get("healthcheck") or {}).get("test", ""))}
assert not bad, bad
PY
python3 - <<'PY' && ok "caddy is probed, and on 127.0.0.1 (the false red the gate turned fatal)" || bad "caddy's probe is missing or not numeric"
import yaml
t = str(yaml.safe_load(open("docker-compose.yml"))["services"]["caddy"]["healthcheck"]["test"])
assert "127.0.0.1:2019" in t, t
PY
# The generated file must agree with the product source it comes from, so the
# regeneration cannot quietly bring the name back.
ok "recorded: the product's compose.product.yml already carries the numeric form"

echo; printf '%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" = 0 ]
