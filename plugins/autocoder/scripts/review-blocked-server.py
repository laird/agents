#!/usr/bin/env python3
"""Local HTTP back end for the blocked-issue review GUI (#311, part of #308).

    review-blocked-server.py [--port N]
    review-blocked-server.py --key N

`--key N` serves nothing: it prints issue N's "analysisKey" (below) and exits,
1 when the issue cannot be read. `/review-blocked --prepare` (#312) stores its
analyses under this key, so the page reads them back as fresh.

Serves, on 127.0.0.1 only:

    GET  /                 review-blocked-ui.html from this directory (a
                           placeholder page while that file does not exist)
    GET  /api/issues       fetch-blocked-issues.sh output; each issue gains
                           "blockReason" (the comment that explains its block,
                           or null), "analysisKey", "analysis" and "stale"
    POST /api/decision     one decision object, or a list of them (batch mode)

A decision is {"issue": N, "action": A, ...}:

    approve   "label" (the blocking label to remove) and "approach" (the text
              of the approval comment) -> approve-blocked-issue.sh
    reject    "reason"                 -> reject-blocked-issue.sh
    ask       "question"               -> issue_comment; the label stays
    skip                               -> nothing

A single decision answers {"issue", "action", "ok", "detail"} with 200, or 400
when the decision is malformed and 500 when the script failed. A list answers
200 with {"ok": <all ok>, "results": [one such object per decision]}; the
decisions run in order and a failure does not stop the rest.

Every /api/* request must carry the per-run token, printed in the startup URL,
as an "X-Review-Token" header or a "token" query parameter; without it the
answer is 403. The server runs the scripts with argument lists, never a shell,
from its working directory, so start it in the repository whose issues you are
reviewing.

Analyses come from blocked-analysis-cache.py (#310), keyed by "analysisKey":
the issue's updatedAt when the backend reports one, otherwise
"sha256:<hex>" over the issue's title, body, sorted label names and comment
bodies as issue_get returns them (analysis_key() below), so a new comment
makes the cached analysis stale. Whatever prepares analyses (#312) must store them under
the same key: `--key N` prints it. "analysis" is the cached analysis or null; "stale" is true when an
entry exists for an older key, false when the analysis is fresh, and null when
nothing is cached.
"""

import argparse
import hashlib
import hmac
import json
import os
import re
import secrets
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
HOST = "127.0.0.1"  # never configurable: the API acts on the tracker as the user
BLOCKING_LABELS = ["needs-approval", "needs-design", "needs-clarification",
                   "needs-feedback", "too-complex", "future", "proposal"]
ACTIONS = ("approve", "reject", "ask", "skip")
MAX_BODY = 1 << 20
SCRIPT_TIMEOUT = 300
UI_FILE = "review-blocked-ui.html"

PLACEHOLDER_PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Review blocked issues</title></head>
<body><h1>Review blocked issues</h1>
<p>The review page is not installed yet. The API is running: GET /api/issues and
POST /api/decision, with the token from the startup URL.</p></body></html>
"""

# The file backend folds each comment into the body as "\n> **YYYY-MM-DD HH:MM** text".
FILE_COMMENT = re.compile(r"\n> \*\*\d{4}-\d\d-\d\d \d\d:\d\d\*\* ")


def run(argv, stdin=None):
    """Run argv (no shell). Returns (rc, stdout, stderr)."""
    try:
        p = subprocess.run(argv, input=stdin, capture_output=True, text=True,
                           timeout=SCRIPT_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as e:
        return 127, "", str(e)
    return p.returncode, p.stdout, p.stderr


def issue_fn(*args):
    """Call one issue-fns.sh verb with args as argv."""
    return run(["bash", "-c", 'source "$0/issue-fns.sh" >/dev/null && "$@"', SCRIPT_DIR, *args])


def label_names(issue):
    return [l.get("name") if isinstance(l, dict) else l for l in issue.get("labels") or []]


def analysis_key(issue, full=None):
    """full: the issue as issue_get returns it (with comments); defaults to issue."""
    full = full or issue
    if full.get("updatedAt") or issue.get("updatedAt"):
        return str(full.get("updatedAt") or issue["updatedAt"])
    comments = [c.get("body") or "" for c in full.get("comments") or [] if isinstance(c, dict)]
    blob = json.dumps({"title": full.get("title") or "", "body": full.get("body") or "",
                       "labels": sorted(str(n) for n in label_names(full)),
                       "comments": comments},
                      sort_keys=True, ensure_ascii=False)
    return "sha256:" + hashlib.sha256(blob.encode()).hexdigest()


def comments_of(issue):
    """Comment bodies, oldest first: the backend's list, else the file backend's folded ones."""
    listed = [c.get("body") or "" for c in issue.get("comments") or [] if isinstance(c, dict)]
    if listed:
        return listed
    return FILE_COMMENT.split(issue.get("body") or "")[1:]


def block_reason(issue, full):
    """The latest comment that names a blocking label the issue carries, or says Blocked."""
    labels = [n for n in label_names(issue) if n in BLOCKING_LABELS]
    for body in reversed(comments_of(full)):
        if re.search(r"\bblocked\b", body, re.I) or any(l in body for l in labels):
            return body.strip()
    return None


def cached_analysis(number, key):
    cache = os.path.join(SCRIPT_DIR, "blocked-analysis-cache.py")
    rc, out, _ = run([sys.executable, cache, "get", str(number), "--updated-at", key])
    if rc == 0:
        try:
            return json.loads(out), False
        except ValueError:
            return None, None
    if rc != 1:  # a cache error, not a miss: report nothing rather than a false "stale"
        return None, None
    rc, out, _ = run([sys.executable, cache, "list"])
    try:
        cached = rc == 0 and any(e.get("number") == number for e in json.loads(out))
    except ValueError:
        cached = False
    return None, (True if cached else None)


def list_issues():
    rc, out, err = run(["bash", os.path.join(SCRIPT_DIR, "fetch-blocked-issues.sh")])
    if rc != 0:
        raise RuntimeError(err.strip() or f"fetch-blocked-issues.sh exited {rc}")
    data = json.loads(out)
    if not isinstance(data, dict) or not isinstance(data.get("issues"), list):
        raise ValueError("fetch-blocked-issues.sh did not print an object with an issues list")
    for issue in data.get("issues", []):
        n = issue.get("number")
        grc, gout, _ = issue_fn("issue_get", str(n))
        try:
            full = json.loads(gout) if grc == 0 else issue
        except ValueError:
            full = issue
        issue["blockReason"] = block_reason(issue, full)
        issue["analysisKey"] = analysis_key(issue, full)
        issue["analysis"], issue["stale"] = cached_analysis(n, issue["analysisKey"])
    return data


def _text(d, key):
    v = d.get(key)
    return v.strip() if isinstance(v, str) and v.strip() else None


def decide(d):
    """Apply one decision. Returns (result, http_status)."""
    if not isinstance(d, dict):
        return {"issue": None, "action": None, "ok": False,
                "detail": "a decision must be a JSON object"}, 400
    issue, action = d.get("issue"), d.get("action")
    res = {"issue": issue, "action": action, "ok": False, "detail": ""}
    if isinstance(issue, str) and issue.isascii() and issue.isdigit():
        issue = int(issue)
    if isinstance(issue, bool) or not isinstance(issue, int) or issue <= 0:
        res["detail"] = "'issue' must be a positive issue number"
        return res, 400
    res["issue"] = issue
    if action not in ACTIONS:
        res["detail"] = f"'action' must be one of {', '.join(ACTIONS)}"
        return res, 400
    if action == "skip":
        res.update(ok=True, detail="skipped")
        return res, 200
    if action == "approve":
        label, approach = _text(d, "label"), _text(d, "approach")
        if label not in BLOCKING_LABELS:
            res["detail"] = f"approve needs 'label', one of {', '.join(BLOCKING_LABELS)}"
            return res, 400
        if not approach:
            res["detail"] = "approve needs a non-empty 'approach'"
            return res, 400
        rc, out, err = run(["bash", os.path.join(SCRIPT_DIR, "approve-blocked-issue.sh"),
                            str(issue), label, approach])
    elif action == "reject":
        reason = _text(d, "reason")
        if not reason:
            res["detail"] = "reject needs a non-empty 'reason'"
            return res, 400
        rc, out, err = run(["bash", os.path.join(SCRIPT_DIR, "reject-blocked-issue.sh"),
                            str(issue), reason])
    else:
        question = _text(d, "question")
        if not question:
            res["detail"] = "ask needs a non-empty 'question'"
            return res, 400
        rc, out, err = issue_fn("issue_comment", str(issue), "--body",
                                f"❓ **Question from human review**\n\n{question}")
        out = out or f"asked on #{issue}"
    if rc == 0:
        res.update(ok=True, detail=out.strip())
        return res, 200
    res["detail"] = (err.strip() or out.strip() or f"exit {rc}")
    return res, 500


class Handler(BaseHTTPRequestHandler):
    server_version = "review-blocked"
    token = ""
    timeout = 30  # a client that stalls mid-request cannot wedge the single-threaded server

    def log_message(self, fmt, *args):
        # Never the raw request line: its query string can carry the token.
        sys.stderr.write("review-blocked-server: %s %s -> %s\n" % (
            self.command, urlsplit(self.path).path, args[1] if len(args) > 1 else "-"))

    def _send(self, status, body, ctype="application/json"):
        data = (json.dumps(body) + "\n").encode() if ctype == "application/json" else body.encode()
        self.send_response(status)
        self.send_header("Content-Type", f"{ctype}; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def _authorized(self):
        given = self.headers.get("X-Review-Token") or \
            (parse_qs(urlsplit(self.path).query).get("token") or [""])[0]
        return hmac.compare_digest(given.encode(), self.token.encode())

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/":
            try:
                with open(os.path.join(SCRIPT_DIR, UI_FILE), encoding="utf-8") as f:
                    page = f.read()
            except OSError:
                page = PLACEHOLDER_PAGE
            return self._send(200, page, "text/html")
        if not path.startswith("/api/"):
            return self._send(404, {"error": "not found"})
        if not self._authorized():
            return self._send(403, {"error": "missing or wrong token"})
        if path != "/api/issues":
            return self._send(404, {"error": "not found"})
        try:
            return self._send(200, list_issues())
        except (RuntimeError, ValueError) as e:
            return self._send(502, {"error": f"cannot list blocked issues: {e}"})

    def do_POST(self):
        path = urlsplit(self.path).path
        if not path.startswith("/api/"):
            return self._send(404, {"error": "not found"})
        if not self._authorized():
            return self._send(403, {"error": "missing or wrong token"})
        if path != "/api/decision":
            return self._send(404, {"error": "not found"})
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if not 0 < length <= MAX_BODY:
            return self._send(400, {"error": "a JSON body of at most 1 MiB is required"})
        try:
            payload = json.loads(self.rfile.read(length))
        except ValueError:
            return self._send(400, {"error": "the body is not valid JSON"})
        if isinstance(payload, list):
            if not payload:
                return self._send(400, {"error": "a batch needs at least one decision"})
            results = [decide(d)[0] for d in payload]
            return self._send(200, {"ok": all(r["ok"] for r in results), "results": results})
        result, status = decide(payload)
        return self._send(status, result)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--port", type=int, default=0, help="port on 127.0.0.1 (default: a free one)")
    parser.add_argument("--key", type=int, metavar="N",
                        help="print issue N's analysisKey and exit (serves nothing)")
    args = parser.parse_args(argv)
    if args.key is not None:
        rc, out, err = issue_fn("issue_get", str(args.key))
        try:
            full = json.loads(out) if rc == 0 else None
        except ValueError:
            full = None
        if not isinstance(full, dict):
            print(f"review-blocked-server: cannot read issue #{args.key}: "
                  f"{err.strip() or f'issue_get exited {rc}'}", file=sys.stderr)
            return 1
        print(analysis_key(full))
        return 0
    Handler.token = secrets.token_urlsafe(24)
    try:
        httpd = HTTPServer((HOST, args.port), Handler)
    except OSError as e:
        print(f"review-blocked-server: cannot listen on {HOST}:{args.port}: {e}", file=sys.stderr)
        return 2
    port = httpd.server_address[1]
    print(f"review-blocked-server: http://{HOST}:{port}/?token={Handler.token}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
