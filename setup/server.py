# opsroom-setup-server
import base64, http.server, json, os, re, sys, urllib.parse, urllib.request, secrets, subprocess
ROOT, ANSWERS, PORT, STATUS, SELF, REPO, TSDNS, OPSUSER, LOG, REGHOST, REGNS, PULLED, RESTORE = sys.argv[1:14]
FORM = open(os.path.join(ROOT, "index.html")).read()

def drop(name, form):
    """Remove one marked block. The form is ONE document carrying every field;
    each mode deletes what it must not ask. A field that is absent cannot be
    half-answered, and a mode that forgets to delete one is a visible bug
    rather than a silent default."""
    return re.sub(r"<!--%s-->.*?<!--/%s-->" % (name, name), "", form, flags=re.S)

if PULLED == "1":
    # Images were already pulled by the front half (env-token / unattended
    # path) — the registry fieldset would be a lie, so it is stripped.
    FORM = drop("REGISTRY", FORM)
if RESTORE == "1":
    # A restore asks for the backup and its two keys. The administrator, the
    # recovery-key CHOICES, the domain package and the invite mode all come
    # back inside the sealed configuration, so asking would either be ignored
    # or would overwrite what was restored.
    for block in ("H-INSTALL", "ADMIN", "RECOVERY", "DISTRO", "INVITES", "OBJSTORE"):
        FORM = drop(block, FORM)
    FORM = FORM.replace("<!--SUBMIT-->Install", "Restore")
    FORM = FORM.replace("<!--WHY-RESTORE-->",
                        " These are read to FIND the backup; the restored configuration "
                        "then supplies the instance's own copy of them.")
    FORM = FORM.replace("<title>OpsRoom setup</title>", "<title>OpsRoom restore</title>")
else:
    FORM = drop("H-RESTORE", FORM)
    FORM = drop("RESTORE", FORM)
    FORM = FORM.replace("<!--SUBMIT-->", "")
# EVERY LEFTOVER MARKER GOES. The blocks a mode keeps still carry their
# <!--NAME--> pair, and a marker that reaches the browser is how a renamed
# block silently stops being deleted — the restore would quietly start asking
# for an administrator again. ERR and VALUES survive: form_page() fills them.
FORM = re.sub(r"<!--/?(?!ERR|VALUES)[A-Z][A-Z0-9-]*-->", "", FORM)
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
# Echoed back on a field error. SECRETS ARE ABSENT BY CONSTRUCTION: no
# password, token or key is ever written into the returned HTML.
KEEP = ("admin_user", "backup_bucket", "s3_endpoint", "s3_key",
        "age_mode", "pass_mode", "invite_mode", "distro", "stamp",
        "obj_base", "obj_endpoint", "obj_key", "obj_region")
def form_page(err_html="", values=None):
    page = FORM.replace("<!--ERR-->", err_html)
    blob = ""
    kept = {k: v for k, v in (values or {}).items() if k in KEEP and v}
    if kept:
        blob = '<script id="prefill" type="application/json">%s</script>' % (
            json.dumps(kept).replace("<", "\\u003c"))
    return page.replace("<!--VALUES-->", blob)
def started():
    """Is an install under way (or finished)? The deploy phase SHREDS the
    answers file early, so its absence does not mean 'nothing is running' —
    the status file is the durable signal. Without this, a refresh (or a
    second device on the tailnet) mid-install gets a blank form back, and
    submitting it would start a second concurrent deploy."""
    try:
        return bool(open(STATUS).read().strip())
    except Exception:
        return False
def coherence(f):
    e = []
    if PULLED != "1":
        t = f.get("pull_token", "").strip()
        if not t: e.append("The registry pull token is required — your vendor provides it.")
        elif not registry_ok(t): e.append("The registry rejected that pull token (or it lacks read access). Check it with your vendor.")
    # Both modes need a bucket to read from or write to, over https.
    for key, label in (("backup_bucket", "Bucket"), ("s3_key", "Access Key ID"),
                       ("s3_secret", "Secret Access Key")):
        if not f.get(key, "").strip():
            e.append("%s is required." % label)
    if not f.get("s3_endpoint", "").startswith("https://"):
        e.append("S3 endpoint must be an https:// URL.")
    if RESTORE == "1":
        # EVERY ONE OF THESE FAILS MINUTES LATER AND HALFWAY THROUGH A DATABASE
        # if it is wrong, so it is checked at submit while the form is still on
        # screen. The stamp is the exception that cannot be checked here:
        # whether it exists is a question for the bucket.
        if not f.get("age_key", "").startswith("AGE-SECRET-KEY-"):
            e.append("The AGE-SECRET-KEY is required to open the backup's configuration, and it starts with AGE-SECRET-KEY-.")
        if not f.get("backup_pass", ""):
            e.append("The backup passphrase is required — it is what decrypts the database dumps.")
        s = f.get("stamp", "")
        if s and not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z", s):
            e.append("A backup is stamped like 20260913T025705Z. Leave it empty for the most recent one.")
        return e
    u = f.get("admin_user", "")
    if not u:
        e.append("An administrator username is required.")
    elif not re.fullmatch(r"[A-Za-z0-9._@-]{2,64}", u):
        e.append("Administrator username: 2-64 characters, letters, digits and . _ @ - only.")
    d = f.get("distro", "")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*@[0-9]+(\.[0-9]+)*|none", d):
        e.append("Domain package: <name>@<version> (for example healthcare@0.1), or none.")
    # FILE STORAGE. After board 150's D3 an instance with no object store
    # cannot take an upload at all, so these are required, not optional.
    ob = f.get("obj_base", "").strip()
    if not ob.startswith("s3://"):
        e.append("The bucket for uploaded files must be an s3:// URL, for example s3://opsroom-data.")
    if not f.get("obj_endpoint", "").startswith("https://"):
        e.append("File storage endpoint must be an https:// URL.")
    for key, label in (("obj_key", "file storage Access Key ID"),
                       ("obj_secret", "file storage Secret Access Key"),
                       ("obj_region", "file storage Region")):
        if not f.get(key, "").strip():
            e.append("The %s is required." % label)
    # TWO BUCKETS, TWO TOKENS (D3), CHECKED HERE BECAUSE NOTHING LATER WILL.
    # Backups rotate and delete; data never does. One bucket for both means
    # retention eventually prunes the files people uploaded, and the backup's
    # own mirror of the data bucket would be copying a bucket into itself.
    bb = f.get("backup_bucket", "").strip().replace("s3://", "")
    if bb and ob and ob.replace("s3://", "").split("/")[0] == bb.split("/")[0]:
        e.append("File storage and backups must be DIFFERENT buckets. Backups are pruned on a timer and uploaded files are not, so one bucket for both eventually deletes people's files.")
    if f.get("obj_key", "").strip() and f.get("obj_key", "").strip() == f.get("s3_key", "").strip():
        e.append("File storage and backups must use DIFFERENT tokens. The backup token is allowed to read the file bucket; the file token must not be able to touch your backups.")
    if f.get("age_mode") == "restore" and not f.get("age_key", "").startswith("AGE-SECRET-KEY-"): e.append("Restore chosen but no AGE-SECRET-KEY given.")
    if f.get("pass_mode") == "provide" and len(f.get("backup_pass", "")) < 16: e.append("Backup passphrase must be at least 16 characters.")
    if f.get("invite_mode") == "magic_link": e.append("magic_link needs SMTP, which this installer does not configure. Choose temporary password.")
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
        self._send(INSTALLING if (os.path.exists(ANSWERS) or started()) else form_page())
    def do_POST(self):
        if os.path.exists(ANSWERS) or started():
            self._send(INSTALLING); return          # already submitted — never deploy twice
        n = int(self.headers.get("Content-Length", 0))
        f = {k: v[0] for k, v in urllib.parse.parse_qs(self.rfile.read(n).decode()).items()}
        # Copy-paste drags whitespace along; a token with a trailing newline
        # is a real typo report, not a bad token. Passwords are NOT stripped.
        for k in ("pull_token", "admin_user", "backup_bucket", "s3_endpoint", "s3_key", "age_key",
                  "distro", "stamp", "obj_base", "obj_endpoint", "obj_key", "obj_region"):
            if k in f: f[k] = f[k].strip()
        errs = coherence(f)
        if errs:
            self._send(form_page('<div class="err">' + "\n".join(errs) + "</div>", f), 400); return
        if RESTORE != "1" and f.get("pass_mode") == "generate": f["backup_pass"] = secrets.token_urlsafe(36)
        with open(ANSWERS, "w") as o: json.dump(f, o)
        os.chmod(ANSWERS, 0o600)
        open(STATUS, "w").write("installing:starting")
        subprocess.Popen(["bash", SELF, "--deploy", REPO, ANSWERS, TSDNS, OPSUSER,
                          "restore" if RESTORE == "1" else "install"],
                         stdin=subprocess.DEVNULL, stdout=open(LOG, "a"), stderr=subprocess.STDOUT, start_new_session=True)
        self._send(INSTALLING)
http.server.HTTPServer(("127.0.0.1", int(PORT)), H).serve_forever()
