# opsroom-setup-server
import http.server, json, os, sys, urllib.parse, secrets, subprocess
ROOT, ANSWERS, PORT, STATUS, SELF, REPO, TSDNS, OPSUSER, LOG = sys.argv[1:10]
FORM = open(os.path.join(ROOT, "index.html")).read()
INSTALLING = open(os.path.join(ROOT, "installing.html")).read()
# The deploy phase kills THIS pid at handover; the browser tells this server
# apart from the product by the X-OpsRoom-Setup header on every reply.
open(os.path.join(ROOT, "server.pid"), "w").write(str(os.getpid()))
def coherence(f):
    e = []
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
