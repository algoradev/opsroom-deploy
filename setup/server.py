# opsroom-setup-server
import base64, http.server, json, os, re, sys, urllib.parse, urllib.request, secrets, subprocess
ROOT, ANSWERS, PORT, STATUS, SELF, REPO, TSDNS, OPSUSER, LOG, REGHOST, REGNS, PULLED = sys.argv[1:13]
FORM = open(os.path.join(ROOT, "index.html")).read()
if PULLED == "1":
    # Images were already pulled by the front half (env-token / unattended
    # path) — the registry fieldset would be a lie, so it is stripped.
    FORM = re.sub(r"<!--REGISTRY-->.*?<!--/REGISTRY-->", "", FORM, flags=re.S)
INSTALLING = open(os.path.join(ROOT, "installing.html")).read()
# The deploy phase kills THIS pid at handover; the browser tells this server
# apart from the product by the X-OpsRoom-Setup header on every reply.
open(os.path.join(ROOT, "server.pid"), "w").write(str(os.getpid()))
def registry_ok(token):
    """Probe the registry with the token — a typo becomes a field error at
    submit, not a stalled install later. Two steps, like docker itself:
    mint a scoped bearer, then read the repo's tag list."""
    try:
        basic = base64.b64encode(("x:" + token).encode()).decode()
        req = urllib.request.Request(
            "https://%s/token?scope=repository:%s/opsroom-api:pull&service=%s" % (REGHOST, REGNS, REGHOST),
            headers={"Authorization": "Basic " + basic})
        bearer = json.load(urllib.request.urlopen(req, timeout=10)).get("token", "")
        req2 = urllib.request.Request(
            "https://%s/v2/%s/opsroom-api/tags/list" % (REGHOST, REGNS),
            headers={"Authorization": "Bearer " + bearer})
        urllib.request.urlopen(req2, timeout=10)
        return True
    except Exception:
        return False
def coherence(f):
    e = []
    if PULLED != "1":
        t = f.get("pull_token", "").strip()
        if not t: e.append("The registry pull token is required — your vendor provides it.")
        elif not registry_ok(t): e.append("The registry rejected that pull token (or it lacks read access). Check it with your vendor.")
    if f.get("age_mode") == "restore" and not f.get("age_key", "").startswith("AGE-SECRET-KEY-"): e.append("Restore chosen but no AGE-SECRET-KEY given.")
    if f.get("pass_mode") == "provide" and len(f.get("backup_pass", "")) < 16: e.append("Backup passphrase must be at least 16 characters.")
    if f.get("invite_mode") == "magic_link": e.append("magic_link needs SMTP, which this installer does not configure. Choose temporary password.")
    if not f.get("s3_endpoint", "").startswith("https://"): e.append("S3 endpoint must be an https:// URL.")
    if len(f.get("admin_pass", "")) < 12: e.append("Admin password must be at least 12 characters.")
    return e
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, body, code=200, ctype="text/html; charset=utf-8"):
        b = body.encode(); self.send_response(code)
        self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(b)))
        self.send_header("X-OpsRoom-Setup", "1"); self.send_header("Cache-Control", "no-store"); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path.startswith("/status"):
            try: s = open(STATUS).read().strip() or "installing:starting"
            except Exception: s = "installing:starting"
            self._send(json.dumps({"status": s}), ctype="application/json"); return
        self._send(INSTALLING if os.path.exists(ANSWERS) else FORM.replace("<!--ERR-->", ""))
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        f = {k: v[0] for k, v in urllib.parse.parse_qs(self.rfile.read(n).decode()).items()}
        errs = coherence(f)
        if errs:
            self._send(FORM.replace("<!--ERR-->", '<div class="err">' + "\n".join(errs) + "</div>"), 400); return
        if f.get("pass_mode") == "generate": f["backup_pass"] = secrets.token_urlsafe(36)
        with open(ANSWERS, "w") as o: json.dump(f, o)
        os.chmod(ANSWERS, 0o600)
        open(STATUS, "w").write("installing:starting")
        subprocess.Popen(["bash", SELF, "--deploy", REPO, ANSWERS, TSDNS, OPSUSER],
                         stdin=subprocess.DEVNULL, stdout=open(LOG, "a"), stderr=subprocess.STDOUT, start_new_session=True)
        self._send(INSTALLING)
http.server.HTTPServer(("127.0.0.1", int(PORT)), H).serve_forever()
