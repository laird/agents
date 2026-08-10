#!/usr/bin/env python3
"""fake_jira.py — a tiny STATEFUL fake of the Jira REST API v2, implementing
exactly the endpoints issues-jira.sh calls, with a real (if minimal) JQL
evaluator so list/any-claimable/blocked genuinely filter.

Not a general Jira emulator — it covers:
  GET  /rest/api/2/myself
  POST /rest/api/3/search/jql            {jql,maxResults,fields,nextPageToken}
                                         → {issues:[...], nextPageToken?}
                                         (no startAt/total — the new contract)
  POST /rest/api/2/search                → HTTP 410 (removed by Atlassian,
                                         CHANGE-2046; pins the regression)
  POST /rest/api/2/issue                 create
  GET  /rest/api/2/issue/{key}           (+?fields=...) / 404
  PUT  /rest/api/2/issue/{key}           update.labels [{add|remove}]
  POST /rest/api/2/issue/{key}/comment
  GET  /rest/api/2/issue/{key}/transitions
  POST /rest/api/2/issue/{key}/transitions   {transition:{id}}
  PUT  /rest/api/2/issue/{key}/assignee

Auth is accepted but ignored. State lives in memory for the process lifetime.
"""
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROJECT = "ENG"
# statusCategory keys: "new" (To Do), "indeterminate" (In Progress), "done".
ISSUES = {}   # number -> dict(summary, description, labels[list], cat, comments[list])
NEXT = [1]

def seed(summary, labels, cat):
    n = NEXT[0]; NEXT[0] += 1
    ISSUES[n] = {"summary": summary, "description": f"seed {summary}",
                 "labels": list(labels), "cat": cat, "comments": []}
    return n

# A representative starting set — note the label-less one and the blocked one.
seed("Unlabeled ready", [], "indeterminate")          # ENG-1: claimable ONLY via the empty-labels guard
seed("Has P1 label", ["P1"], "new")                   # ENG-2: claimable (P1 not blocking)
seed("Blocked on design", ["needs-design"], "indeterminate")  # ENG-3: blocked, not claimable
seed("Already claimed", ["working"], "indeterminate") # ENG-4: working, not claimable
seed("Finished work", [], "done")                     # ENG-5: closed only

def to_adf(text):
    """Wrap plain text in the minimal ADF doc/paragraph/text structure that
    v3 search really returns for `description` (one paragraph per line)."""
    return {"type": "doc", "version": 1, "content": [
        {"type": "paragraph",
         "content": ([{"type": "text", "text": p}] if p else [])}
        for p in (text or "").split("\n")
    ]}

def status_obj(cat):
    name = {"new": "To Do", "indeterminate": "In Progress", "done": "Done"}[cat]
    return {"name": name, "statusCategory": {"key": cat}}

def to_view(n):
    it = ISSUES[n]
    return {
        "key": f"{PROJECT}-{n}",
        "fields": {
            "summary": it["summary"],
            "description": it["description"],
            "labels": it["labels"],
            "status": status_obj(it["cat"]),
            "comment": {"comments": [{"body": b} for b in it["comments"]]},
        },
    }

def jql_matches(n, jql):
    it = ISSUES[n]
    labels = set(it["labels"])
    m = re.search(r'project\s*=\s*"([^"]+)"', jql)
    if m and m.group(1) != PROJECT:
        return False
    if "statusCategory != Done" in jql and it["cat"] == "done":
        return False
    if "statusCategory = Done" in jql and it["cat"] != "done":
        return False
    mnot = re.search(r'labels not in \(([^)]*)\)', jql)
    if mnot:
        blocked = set(re.findall(r'"([^"]+)"', mnot.group(1)))
        empty_ok = "labels is EMPTY" in jql
        if labels & blocked:
            return False
        if not labels and not empty_ok:
            return False
    else:
        min_ = re.search(r'labels in \(([^)]*)\)', jql)
        if min_:
            wanted = set(re.findall(r'"([^"]+)"', min_.group(1)))
            if not (labels & wanted):
                return False
    meq = re.search(r'labels\s*=\s*"([^"]+)"', jql)
    if meq and meq.group(1) not in labels:
        return False
    return True

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet
        pass

    def _send(self, code, obj=None):
        self.send_response(code)
        if obj is not None:
            body = json.dumps(obj).encode()
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_header("Content-Length", "0")
            self.end_headers()

    def _body(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        return json.loads(self.rfile.read(n) or b"{}") if n else {}

    def _key_num(self, key):
        m = re.match(rf'{PROJECT}-(\d+)$', key)
        return int(m.group(1)) if m else None

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/rest/api/2/myself":
            return self._send(200, {"accountId": "fake", "emailAddress": "fake@local"})
        m = re.match(r'/rest/api/2/issue/([^/]+)/transitions$', path)
        if m:
            return self._send(200, {"transitions": [
                {"id": "31", "name": "Done", "to": {"statusCategory": {"key": "done"}}},
                {"id": "11", "name": "To Do", "to": {"statusCategory": {"key": "new"}}},
            ]})
        m = re.match(r'/rest/api/2/issue/([^/]+)$', path)
        if m:
            n = self._key_num(m.group(1))
            if n in ISSUES:
                return self._send(200, to_view(n))
            return self._send(404, {"errorMessages": ["Issue does not exist"]})
        return self._send(404, {"errorMessages": ["not found"]})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        body = self._body()
        if path == "/rest/api/2/search":
            # Removed by Atlassian (CHANGE-2046). Real Jira Cloud returns 410
            # with a migration pointer; serving it here pins the regression.
            return self._send(410, {"errorMessages": [
                "The requested API has been removed. Please migrate to "
                "/rest/api/3/search/jql. See "
                "https://developer.atlassian.com/changelog/#CHANGE-2046"
            ], "errors": {}})
        if path == "/rest/api/3/search/jql":
            jql = body.get("jql", "")
            maxr = int(body.get("maxResults", 50))
            # Like real Jira Cloud, the server enforces its own page-size cap
            # regardless of the requested maxResults. Tests set a small
            # FAKE_JIRA_PAGE_CAP to force multi-page nextPageToken traversal.
            maxr = max(1, min(maxr, int(os.environ.get("FAKE_JIRA_PAGE_CAP", "100"))))
            fields = body.get("fields") or []
            token = body.get("nextPageToken")
            start = 0
            if token is not None:
                try:
                    start = int(token)
                except (TypeError, ValueError):
                    return self._send(400, {"errorMessages": ["Invalid nextPageToken"]})
            hits = [n for n in sorted(ISSUES) if jql_matches(n, jql)]
            page = hits[start:start + maxr]
            issues = []
            for n in page:
                view = to_view(n)
                # New contract: field data is returned ONLY for requested
                # fields (the API defaults to id-only). id/key always present.
                view["id"] = str(1000 + n)
                view["fields"] = {k: v for k, v in view["fields"].items() if k in fields}
                # v3 search returns description as an ADF document object,
                # NOT v2's plain string (v2 CRUD reads still return strings).
                if "description" in view["fields"]:
                    view["fields"]["description"] = to_adf(view["fields"]["description"])
                issues.append(view)
            resp = {"issues": issues}
            if start + maxr < len(hits):
                resp["nextPageToken"] = str(start + maxr)
            return self._send(200, resp)
        if path == "/rest/api/2/issue":
            f = body.get("fields", {})
            n = NEXT[0]; NEXT[0] += 1
            ISSUES[n] = {"summary": f.get("summary", ""), "description": f.get("description", ""),
                         "labels": list(f.get("labels", [])), "cat": "new", "comments": []}
            return self._send(201, {"id": str(1000 + n), "key": f"{PROJECT}-{n}"})
        m = re.match(r'/rest/api/2/issue/([^/]+)/comment$', path)
        if m:
            n = self._key_num(m.group(1))
            if n in ISSUES:
                ISSUES[n]["comments"].append(body.get("body", ""))
                return self._send(201, {"id": "9999", "body": body.get("body", "")})
            return self._send(404, {"errorMessages": ["no issue"]})
        m = re.match(r'/rest/api/2/issue/([^/]+)/transitions$', path)
        if m:
            n = self._key_num(m.group(1))
            tid = str((body.get("transition") or {}).get("id", ""))
            if n in ISSUES:
                if tid == "31":
                    ISSUES[n]["cat"] = "done"
                elif tid == "11":
                    ISSUES[n]["cat"] = "new"
                return self._send(204)
            return self._send(404, {"errorMessages": ["no issue"]})
        return self._send(404, {"errorMessages": ["not found"]})

    def do_PUT(self):
        path = self.path.split("?", 1)[0]
        body = self._body()
        m = re.match(r'/rest/api/2/issue/([^/]+)/assignee$', path)
        if m:
            return self._send(204)
        m = re.match(r'/rest/api/2/issue/([^/]+)$', path)
        if m:
            n = self._key_num(m.group(1))
            if n not in ISSUES:
                return self._send(404, {"errorMessages": ["no issue"]})
            for op in (body.get("update", {}) or {}).get("labels", []):
                if "add" in op and op["add"] not in ISSUES[n]["labels"]:
                    ISSUES[n]["labels"].append(op["add"])
                if "remove" in op and op["remove"] in ISSUES[n]["labels"]:
                    ISSUES[n]["labels"].remove(op["remove"])
            return self._send(204)
        return self._send(404, {"errorMessages": ["not found"]})

if __name__ == "__main__":
    # Port 0 (the default) binds an ephemeral OS-assigned port so parallel/CI
    # runs never collide. The chosen port is printed as "LISTENING <port>" on
    # the first stdout line (flushed) so a launching test can read it back.
    requested = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    server = ThreadingHTTPServer(("127.0.0.1", requested), H)
    print("LISTENING %d" % server.server_address[1], flush=True)
    server.serve_forever()
