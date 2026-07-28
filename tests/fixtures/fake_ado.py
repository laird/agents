#!/usr/bin/env python3
"""fake_ado.py — a tiny STATEFUL fake of the Azure DevOps Work Item Tracking
REST API, implementing exactly the endpoints issues-ado.sh calls, with a
minimal WIQL evaluator so list/any-claimable/blocked genuinely filter.

Covers (project prefix ignored; routing keys off the /_apis/wit/... suffix):
  POST /_apis/wit/wiql                    {query}         -> {workItems:[{id}]}
  POST /_apis/wit/workitemsbatch          {ids,fields}    -> {value:[{id,fields}]}
  POST /_apis/wit/workitems/$Type         json-patch      -> {id,fields}   (create)
  GET  /_apis/wit/workitems/{id}                          -> {id,fields} / 404
  PATCH/_apis/wit/workitems/{id}          json-patch      -> {id,fields}
  GET  /_apis/wit/workItems/{id}/comments                 -> {comments:[{text}]}
  POST /_apis/wit/workItems/{id}/comments {text}          -> {id,text}

Auth is accepted but ignored. State lives in memory for the process lifetime.
The chosen port is printed as "LISTENING <port>" on the first stdout line.
"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DONE = {"Closed", "Done", "Resolved", "Removed", "Completed"}
ITEMS = {}   # id -> {"fields": {...}, "comments": [text, ...]}
NEXT = [1]

def seed(title, tags, state):
    n = NEXT[0]; NEXT[0] += 1
    ITEMS[n] = {"fields": {"System.Title": title, "System.Description": f"seed {title}",
                           "System.Tags": tags, "System.State": state}, "comments": []}
    return n

# id 1 is deliberately UNTAGGED + not-done: it must stay claimable, proving that
# `[System.Tags] NOT CONTAINS ...` does not drop tag-less work items.
seed("Unlabeled ready", "", "Active")            # 1: claimable
seed("Has P1 tag", "P1", "New")                  # 2: claimable
seed("Blocked on design", "needs-design", "Active")  # 3: blocked
seed("Already claimed", "working", "Active")     # 4: working
seed("Finished work", "", "Closed")              # 5: closed

def tags_of(n):
    return [t.strip() for t in (ITEMS[n]["fields"].get("System.Tags") or "").split(";") if t.strip()]

def wiql_matches(n, q):
    state = ITEMS[n]["fields"].get("System.State") or ""
    tags = set(tags_of(n))
    work = q

    # State membership.
    m = re.search(r"System\.State\]\s+NOT IN \(([^)]*)\)", work)
    if m and state in set(re.findall(r"'([^']+)'", m.group(1))):
        return False
    m = re.search(r"System\.State\]\s+IN \(([^)]*)\)", work)
    if m and state not in set(re.findall(r"'([^']+)'", m.group(1))):
        return False

    # NOT CONTAINS tags: each named tag must be absent.
    for t in re.findall(r"System\.Tags\]\s+NOT CONTAINS '([^']+)'", work):
        if t in tags:
            return False

    # Parenthesised OR-group of CONTAINS (the `blocked` query): at least one.
    org = re.search(r"\(([^)]*CONTAINS[^)]*)\)", work)
    or_tags = []
    if org:
        or_tags = re.findall(r"CONTAINS '([^']+)'", org.group(1))
        work = work[:org.start()] + work[org.end():]  # don't double-count below

    # Remaining mandatory CONTAINS (working-state filter, --label): each present.
    work_wo_not = re.sub(r"System\.Tags\]\s+NOT CONTAINS '[^']+'", "", work)
    for t in re.findall(r"System\.Tags\]\s+CONTAINS '([^']+)'", work_wo_not):
        if t not in tags:
            return False

    if or_tags and not (set(or_tags) & tags):
        return False
    return True

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
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

    def _view(self, n, fields=None):
        f = ITEMS[n]["fields"]
        if fields:
            f = {k: f.get(k) for k in fields if k in f or k == "System.Id"}
        return {"id": n, "fields": {k: v for k, v in ITEMS[n]["fields"].items()}}

    def do_GET(self):
        path = self.path.split("?", 1)[0].lower()
        m = re.search(r"/_apis/wit/workitems/(\d+)/comments$", path)
        if m:
            n = int(m.group(1))
            if n in ITEMS:
                return self._send(200, {"comments": [{"text": t} for t in ITEMS[n]["comments"]]})
            return self._send(200, {"comments": []})
        m = re.search(r"/_apis/wit/workitems/(\d+)$", path)
        if m:
            n = int(m.group(1))
            if n in ITEMS:
                return self._send(200, self._view(n))
            return self._send(404, {"message": "does not exist"})
        return self._send(404, {"message": "not found"})

    def _apply_patch(self, n, ops):
        for op in ops:
            path = op.get("path", "")
            if path.startswith("/fields/"):
                ITEMS[n]["fields"][path[len("/fields/"):]] = op.get("value")

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        low = path.lower()
        body = self._body()
        if low.endswith("/_apis/wit/wiql"):
            q = body.get("query", "")
            hits = [n for n in sorted(ITEMS) if wiql_matches(n, q)]
            return self._send(200, {"workItems": [{"id": n} for n in hits]})
        if low.endswith("/_apis/wit/workitemsbatch"):
            ids = body.get("ids", [])
            fields = body.get("fields")
            val = [self._view(n, fields) for n in ids if n in ITEMS]
            return self._send(200, {"value": val})
        m = re.search(r"/_apis/wit/workitems/%24", low)
        if m:  # create
            n = NEXT[0]; NEXT[0] += 1
            ITEMS[n] = {"fields": {"System.State": "New"}, "comments": []}
            self._apply_patch(n, body if isinstance(body, list) else [])
            return self._send(200, self._view(n))
        m = re.search(r"/_apis/wit/workitems/(\d+)/comments$", low)
        if m:
            n = int(m.group(1))
            if n in ITEMS:
                ITEMS[n]["comments"].append(body.get("text", ""))
                return self._send(200, {"id": 1, "text": body.get("text", "")})
            return self._send(404, {"message": "no item"})
        return self._send(404, {"message": "not found"})

    def do_PATCH(self):
        path = self.path.split("?", 1)[0].lower()
        body = self._body()
        m = re.search(r"/_apis/wit/workitems/(\d+)$", path)
        if m:
            n = int(m.group(1))
            if n not in ITEMS:
                return self._send(404, {"message": "no item"})
            self._apply_patch(n, body if isinstance(body, list) else [])
            return self._send(200, self._view(n))
        return self._send(404, {"message": "not found"})

if __name__ == "__main__":
    requested = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    server = ThreadingHTTPServer(("127.0.0.1", requested), H)
    print("LISTENING %d" % server.server_address[1], flush=True)
    server.serve_forever()
