#!/usr/bin/env python3
"""fake_ado.py — a tiny STATEFUL fake of the Azure DevOps Work Item Tracking
REST API, implementing exactly the endpoints issues-ado.sh calls, with a
minimal WIQL evaluator so list/any-claimable/blocked genuinely filter.

Covers (project prefix ignored; routing keys off the /_apis/wit/... suffix):
  POST /_apis/wit/wiql                    {query}         -> {workItems:[{id}]}
  POST /_apis/wit/workitemsbatch          {ids,fields}    -> {value:[{id,fields}]}
  POST /_apis/wit/workitems/$Type         json-patch      -> {id,fields}   (create)
  GET  /_apis/wit/workitems/{id}[?$expand=relations]      -> {id,rev,url,fields[,relations]} / 404
  PATCH/_apis/wit/workitems/{id}          json-patch      -> {id,...}
       (fields writes; /relations/- add — duplicate relation -> 400, like
        real ADO; /relations/<idx> remove; test op on /rev -> 409 on mismatch)
  GET  /_apis/wit/workItems/{id}/comments                 -> {comments:[{text}]}
  POST /_apis/wit/workItems/{id}/comments {text}          -> {id,text}

Like the real API, `relations` is returned ONLY when the request asks for
$expand=relations (the WorkItemExpand default is None, which omits them).

Failure/behavior toggles (read at request time, set at launch by tests):
  FAKE_ADO_SEED_MODE=deps      seed a dependency scenario instead of the
                               default set (1 = busy blocker w/ working tag +
                               link 1-blocks-2, 2 = blocked, 3 = free)
  FAKE_ADO_500_ON_ITEM=<n>     GET /_apis/wit/workitems/<n> returns 500
  FAKE_ADO_404_ON_ITEM=<n>     GET /_apis/wit/workitems/<n> returns 404
                               (simulates a dangling blocker: relations on
                               other items still render, the direct read is gone)
  FAKE_ADO_INJECT_DUP_ON_PATCH=1   the FIRST /relations/- add PATCH applies
                               the edge server-side, then returns 400
                               "relation already exists" — the losing side of
                               a duplicate-add race against a concurrent writer
  FAKE_ADO_BUMP_REV_ON_FIRST_PATCH=1   the FIRST PATCH carrying a /rev test op
                               bumps the item's rev, then returns 409 — a
                               concurrent revision landing between the
                               client's GET and its guarded PATCH
  FAKE_ADO_BUMP_REV_ON_EVERY_PATCH=1   same, but on EVERY such PATCH (drives
                               the bounded-retry second-conflict → exit 3 path)

Auth is accepted but ignored. State lives in memory for the process lifetime.
The chosen port is printed as "LISTENING <port>" on the first stdout line.
"""
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DONE = {"Closed", "Done", "Resolved", "Removed", "Completed"}
ITEMS = {}   # id -> {"fields": {...}, "comments": [text, ...], "rev": int}
NEXT = [1]

# One-shot race-injection state (benign-write-race tests): each FIRST-only
# toggle fires on its first qualifying PATCH, then behaves normally.
RACE_STATE = {"dup_injected": False, "rev_bumped": False}

# Dependency links, stored as shared edges exactly like real ADO work-item
# links: ONE link renders on both ends — Dependency-Reverse (Predecessor =
# blocker) on the blocked item, Dependency-Forward (Successor = blocked) on
# the blocker — and removing it from either end removes it everywhere.
LINKS = {}       # link id -> {"blocker": n, "blocked": n}
NEXT_LINK = [1]
# Direction per Microsoft's Azure DevOps link-type reference
# (learn.microsoft.com/en-us/azure/devops/boards/queries/link-type-reference):
# System.LinkTypes.Dependency-Reverse = Predecessor (must complete first =
# the BLOCKER), Dependency-Forward = Successor (the blocked item) — verified
# against that reference during review 20260919-165737-281a02d1; independent
# of plugins/autocoder/scripts/issues-ado.sh so a joint direction flip cannot
# pass silently.
REL_BLOCKED_BY = "System.LinkTypes.Dependency-Reverse"
REL_BLOCKS = "System.LinkTypes.Dependency-Forward"

def item_url(n):
    return f"http://fake.ado/_apis/wit/workItems/{n}"

def seed(title, tags, state):
    n = NEXT[0]; NEXT[0] += 1
    ITEMS[n] = {"fields": {"System.Title": title, "System.Description": f"seed {title}",
                           "System.Tags": tags, "System.State": state},
                "comments": [], "rev": 1}
    return n

def add_link(blocker, blocked):
    lid = NEXT_LINK[0]; NEXT_LINK[0] += 1
    LINKS[lid] = {"blocker": blocker, "blocked": blocked}
    return lid

if os.environ.get("FAKE_ADO_SEED_MODE") == "deps":
    # Dependency scenario: 1 is a busy (working-tagged, so unclaimable but
    # OPEN) blocker of 2; 3 is free. The claimable candidates are 2 and 3 in
    # that order — first blocked, second claimable, exactly the KTD8
    # skip-and-continue shape any-claimable must handle.
    seed("Busy blocker", "working", "Active")    # 1
    seed("Blocked child", "", "New")             # 2, blocked by 1
    seed("Free ready", "", "New")                # 3
    add_link(1, 2)
else:
    # id 1 is deliberately UNTAGGED + not-done: it must stay claimable, proving that
    # `[System.Tags] NOT CONTAINS ...` does not drop tag-less work items.
    seed("Unlabeled ready", "", "Active")            # 1: claimable
    seed("Has P1 tag", "P1", "New")                  # 2: claimable
    seed("Blocked on design", "needs-design", "Active")  # 3: blocked
    seed("Already claimed", "working", "Active")     # 4: working
    seed("Finished work", "", "Closed")              # 5: closed

def rel_entries(n):
    # (link id, rendered relation) pairs for item n, in a DETERMINISTIC order
    # (link-id order). The same function backs both the GET rendering and
    # remove-by-index, so indexes always agree with what the client last read.
    out = []
    for lid, l in sorted(LINKS.items()):
        if l["blocked"] == n:
            out.append((lid, {"rel": REL_BLOCKED_BY, "url": item_url(l["blocker"])}))
        if l["blocker"] == n:
            out.append((lid, {"rel": REL_BLOCKS, "url": item_url(l["blocked"])}))
    return out

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

    def _view(self, n, fields=None, expand_relations=False):
        # Like real ADO, a requested-fields list (workitemsbatch "fields")
        # narrows the returned fields dict; the full dict is returned only
        # when no fields list was requested.
        f = ITEMS[n]["fields"]
        if fields:
            f = {k: f.get(k) for k in fields if k in f or k == "System.Id"}
        else:
            f = dict(f)
        view = {"id": n, "rev": ITEMS[n]["rev"], "url": item_url(n), "fields": f}
        if expand_relations:
            # Only on request — the real API's $expand default (None) omits
            # the relations array entirely.
            view["relations"] = [r for _, r in rel_entries(n)]
        return view

    def do_GET(self):
        path, _, query = self.path.partition("?")
        path = path.lower()
        expand_relations = "expand=relations" in query.lower()
        m = re.search(r"/_apis/wit/workitems/(\d+)/comments$", path)
        if m:
            n = int(m.group(1))
            if n in ITEMS:
                return self._send(200, {"comments": [{"text": t} for t in ITEMS[n]["comments"]]})
            return self._send(200, {"comments": []})
        m = re.search(r"/_apis/wit/workitems/(\d+)$", path)
        if m:
            n = int(m.group(1))
            if str(n) == os.environ.get("FAKE_ADO_500_ON_ITEM"):
                return self._send(500, {"message": "injected failure"})
            if str(n) == os.environ.get("FAKE_ADO_404_ON_ITEM"):
                return self._send(404, {"message": "does not exist"})
            if n in ITEMS:
                return self._send(200, self._view(n, expand_relations=expand_relations))
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
            ITEMS[n] = {"fields": {"System.State": "New"}, "comments": [], "rev": 1}
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
        if not m:
            return self._send(404, {"message": "not found"})
        n = int(m.group(1))
        if n not in ITEMS:
            return self._send(404, {"message": "no item"})
        ops = body if isinstance(body, list) else []
        touched = {n}
        for op in ops:
            o, path_ = op.get("op"), op.get("path", "")
            if o == "test" and path_ == "/rev":
                # Injected rev race: a concurrent revision lands between the
                # client's GET and this guarded PATCH — bump the rev (the
                # state the conflicting writer left behind) and fail the
                # test. The retrying client's fresh GET sees the new rev.
                if (os.environ.get("FAKE_ADO_BUMP_REV_ON_EVERY_PATCH") == "1"
                        or (os.environ.get("FAKE_ADO_BUMP_REV_ON_FIRST_PATCH") == "1"
                            and not RACE_STATE["rev_bumped"])):
                    RACE_STATE["rev_bumped"] = True
                    ITEMS[n]["rev"] += 1
                    return self._send(409, {"message": "test operation for /rev failed (injected conflict)"})
                # JSON-patch rev guard: a stale rev fails the WHOLE patch
                # (backend maps any >=400 to exit 3).
                if op.get("value") != ITEMS[n]["rev"]:
                    return self._send(409, {"message": "test operation for /rev failed"})
            elif path_.startswith("/fields/"):
                ITEMS[n]["fields"][path_[len("/fields/"):]] = op.get("value")
            elif o == "add" and path_ == "/relations/-":
                val = op.get("value") or {}
                rel = val.get("rel")
                tail = (val.get("url") or "").rstrip("/").rsplit("/", 1)[-1]
                if not tail.isdigit():
                    return self._send(400, {"message": "bad relation url"})
                t = int(tail)
                if rel == REL_BLOCKED_BY:
                    blocker, blocked = t, n
                elif rel == REL_BLOCKS:
                    blocker, blocked = n, t
                else:
                    return self._send(400, {"message": "unknown relation type"})
                if (os.environ.get("FAKE_ADO_INJECT_DUP_ON_PATCH") == "1"
                        and not RACE_STATE["dup_injected"]):
                    # Injected duplicate-add race: a concurrent writer created
                    # the same edge between the client's pre-read and this
                    # PATCH. Apply the edge server-side (revising both ends,
                    # as the winning write did), then answer 400 exactly as
                    # real ADO does for the losing duplicate.
                    RACE_STATE["dup_injected"] = True
                    if not any(l["blocker"] == blocker and l["blocked"] == blocked
                               for l in LINKS.values()):
                        add_link(blocker, blocked)
                        for e in {blocker, blocked}:
                            if e in ITEMS:
                                ITEMS[e]["rev"] += 1
                    return self._send(400, {"message": "relation already exists"})
                if any(l["blocker"] == blocker and l["blocked"] == blocked
                       for l in LINKS.values()):
                    # Real ADO rejects a duplicate relation with HTTP 400 —
                    # this pins the backend's load-bearing idempotence pre-read.
                    return self._send(400, {"message": "relation already exists"})
                add_link(blocker, blocked)
                touched.add(t)
            elif o == "remove" and re.match(r"^/relations/\d+$", path_):
                idx = int(path_.rsplit("/", 1)[-1])
                rendered = rel_entries(n)
                if idx >= len(rendered):
                    return self._send(400, {"message": "relation index out of range"})
                lid = rendered[idx][0]
                other = LINKS[lid]["blocker"] if LINKS[lid]["blocked"] == n else LINKS[lid]["blocked"]
                del LINKS[lid]
                touched.add(other)
        for t in touched:
            if t in ITEMS:
                ITEMS[t]["rev"] += 1   # like real ADO, both link ends revise
        return self._send(200, self._view(n))

if __name__ == "__main__":
    requested = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    server = ThreadingHTTPServer(("127.0.0.1", requested), H)
    print("LISTENING %d" % server.server_address[1], flush=True)
    server.serve_forever()
