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
ns = {"re": re, "PULLED": "1", "registry_ok": lambda t: True}
exec(compile(ast.Module([fn], []), "server.py", "exec"), ns)
base = {"admin_user": "dave", "backup_bucket": "b", "s3_key": "k", "s3_secret": "s", "s3_endpoint": "https://x", "admin_pass": "x"*12}
def errs(d): return [e for e in ns["coherence"]({**base, "distro": d}) if "Domain package" in e]
for good in ("healthcare@0.1", "none", "x-y@1.2.3"): assert not errs(good), good
for badv in ("", "Healthcare@1", "foo", "foo@", "@1"): assert errs(badv), badv
PY

echo; printf '%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" = 0 ]
