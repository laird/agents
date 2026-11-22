"""merge queue and train planner (train_lib.py, merge-train.py): READY pickup, overrides, classification,
ordering, the planner (next candidate on conflict, prefilter first, stacks at their tip, a failed merge
cleared) and the mechanical reopen, over a real git fixture repo and the file issue backend."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parent.parent / "plugins" / "autocoder" / "scripts"
sys.path.insert(0, str(SCRIPTS))
import train_lib as T  # noqa: E402

CLI = SCRIPTS / "merge-train.py"
ISSUES_FILE = SCRIPTS / "issues-file.py"


def sh(*cmd, cwd=None, env=None, check=True):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env={**os.environ, **(env or {})})
    if check and r.returncode != 0:
        raise AssertionError(f"{cmd} failed: {r.stdout}{r.stderr}")
    return r


class Fixture:
    def __init__(self, root: Path, config=None):
        self.root = root
        self.origin = root / "origin.git"
        self.work = root / "work"
        self.issues = root / "issues"
        self.env = {"ISSUE_DIR_PATH": str(self.issues), "XDG_STATE_HOME": str(root / "state"), "AUTOCODER_TRAIN_SCRATCH": str(root / "scratch"),
                    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
                    "AUTOCODER_ISSUE_EVENTS": str(root / "events.jsonl")}
        os.environ.update(self.env)
        sh("git", "init", "-q", "--bare", str(self.origin))
        sh("git", "init", "-q", "-b", "master", str(self.work))
        (self.work / "README.md").write_text("base\n")
        (self.work / "registry.txt").write_text("a\n")
        (self.work / "data.bin").write_text("0\n")
        (self.work / ".gitattributes").write_text("registry.txt merge=union\ndata.bin merge=binary\n")
        sh("git", "add", "-A", cwd=self.work)
        sh("git", "commit", "-q", "-m", "init", cwd=self.work)
        sh("git", "remote", "add", "origin", str(self.origin), cwd=self.work)
        sh("git", "push", "-q", "origin", "master", cwd=self.work)
        sh("git", "fetch", "-q", "origin", cwd=self.work)
        (self.work / ".git/info/exclude").write_text(".autocoder.json\n")   # config must survive branch checkouts
        # the fixture's branches (`feature/x`) carry no issue number: ownership is off unless a test turns it on
        cfg = {"issueSource": "file", "issueDir": str(self.issues), "train": {"branchOwnership": "any", **(config or {})}}
        (self.work / ".autocoder.json").write_text(json.dumps(cfg))
        sh("git", "update-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/master", cwd=self.work)

    def cfg(self):
        return T.load_config(self.work)

    def branch(self, name, files, base="master"):
        """Commit <files> on a new branch cut from <base> (a ref in origin) and push it."""
        sh("git", "checkout", "-q", "-B", name, f"origin/{base}", cwd=self.work)
        for p, c in files.items():
            (self.work / p).parent.mkdir(parents=True, exist_ok=True)
            (self.work / p).write_text(c)
        sh("git", "add", "-A", cwd=self.work)
        sh("git", "commit", "-q", "-m", f"work on {name}", cwd=self.work)
        sh("git", "push", "-q", "-f", "origin", name, cwd=self.work)
        sh("git", "checkout", "-q", "master", cwd=self.work)
        sh("git", "fetch", "-q", "origin", cwd=self.work)

    def land(self, name, how="merge"):
        """Land the branch on master and push: a merge commit, a rebase (cherry-pick of its commits) or a
        squash (one commit, as the gate lands a branch that holds merge commits)."""
        sh("git", "checkout", "-q", "-B", "master", "origin/master", cwd=self.work)
        if how == "merge":
            sh("git", "merge", "-q", "--no-ff", "-m", f"land {name}", f"origin/{name}", cwd=self.work)
        elif how == "rebase":
            sh("git", "cherry-pick", f"origin/master..origin/{name}", cwd=self.work)
        else:
            sh("git", "merge", "-q", "--squash", f"origin/{name}", cwd=self.work)
            sh("git", "commit", "-q", "-m", f"squash of {name}", cwd=self.work)
        sh("git", "push", "-q", "origin", "master", cwd=self.work)
        sh("git", "fetch", "-q", "origin", cwd=self.work)

    def commit_on(self, name, files, message="more"):
        """One more commit on an existing branch (or on master), pushed."""
        sh("git", "checkout", "-q", "-B", name, f"origin/{name}", cwd=self.work)
        for p, c in files.items():
            (self.work / p).parent.mkdir(parents=True, exist_ok=True)
            if c is None:
                (self.work / p).unlink()
            else:
                (self.work / p).write_text(c)
        sh("git", "add", "-A", cwd=self.work)
        sh("git", "commit", "-q", "-m", message, cwd=self.work)
        sh("git", "push", "-q", "origin", name, cwd=self.work)
        sh("git", "checkout", "-q", "master", cwd=self.work)
        sh("git", "fetch", "-q", "origin", cwd=self.work)

    def issue(self, title, labels=("ready-for-review",), body=""):
        r = sh(sys.executable, str(ISSUES_FILE), "create", "--title", title, "--body", body,
               *[x for lb in labels for x in ("--label", lb)], cwd=self.work)
        return json.loads(r.stdout)["number"]

    def comment(self, n, body):
        sh(sys.executable, str(ISSUES_FILE), "comment", str(n), "--body", body, cwd=self.work)

    def ready(self, title, branch, labels=("ready-for-review",)):
        n = self.issue(title, labels)
        self.comment(n, f"READY on `{branch}`")
        return n

    def queue(self, **kw):
        return {r["issue"]: r for r in T.plan_queue(self.cfg(), **kw)}

    def plan(self, size=None, **kw):
        cfg = self.cfg()
        return T.plan_train(cfg, T.plan_queue(cfg, **kw), size)


@pytest.fixture
def fx(tmp_path):
    return Fixture(tmp_path)


# ── READY parsing ───────────────────────────────────────────────────────────────────────
def test_branch_candidates_keeps_branch_shapes_only():
    body = "READY `feature/x-1` and `origin/fix/y`, see `docs/page.md`, `master`, `develop`, `feature/x-1`, `notabranch`"
    assert T.branch_candidates(body) == ["feature/x-1", "fix/y"]


def test_ready_comments_reads_blockquote_comments_of_the_file_backend():
    issue = {"body": "spec text\n\n> **2026-11-21 02:00** READY on `a/b`\n> second line\n> **2026-11-21 03:30** another",
             "comments": []}
    cs = T.ready_comments(issue)
    assert [c["createdAt"] for c in cs] == ["2026-11-21T02:00:00Z", "2026-11-21T03:30:00Z"]
    assert cs[0]["body"] == "READY on `a/b`\nsecond line"


def test_ready_comments_keeps_a_multi_line_file_backend_comment_whole():
    """issues-file.py writes a multi-line comment with its first line in the blockquote header and the rest as
    written; every line up to the next header is that comment (the enqueue.sh block is read back whole)."""
    issue = {"body": "spec\n\n> **2026-11-21 02:00** READY `a/b` @ abc\n\n```\n=== preflight (enqueue.sh): PASS === x\n```\nflag: none\n> **2026-11-21 03:00** later", "comments": []}
    cs = T.ready_comments(issue)
    assert [c["createdAt"] for c in cs] == ["2026-11-21T02:00:00Z", "2026-11-21T03:00:00Z"]
    assert cs[0]["body"] == "READY `a/b` @ abc\n\n```\n=== preflight (enqueue.sh): PASS === x\n```\nflag: none"
    assert cs[1]["body"] == "later"


def test_ready_comments_keeps_tracker_timestamps_and_none_when_absent():
    issue = {"comments": [{"body": "x", "createdAt": "2026-01-01T00:00:00Z"}, {"body": "y"}]}
    assert [c["createdAt"] for c in T.ready_comments(issue)] == ["2026-01-01T00:00:00Z", None]


def test_pick_ready_prefers_the_newest_ready_naming_an_existing_branch(fx):
    fx.branch("feature/real", {"a.txt": "1\n"})
    cfg = fx.cfg()
    cs = [{"body": "READY `feature/real`", "createdAt": None},
          {"body": "rebase and re-READY, no branch named", "createdAt": None},
          {"body": "READY `feature/gone`", "createdAt": None}]
    assert T.pick_ready(cfg, cs, 1)["branch"] == "feature/real"


def test_pick_ready_reports_the_tried_names_when_none_exists(fx):
    p = T.pick_ready(fx.cfg(), [{"body": "READY `feature/gone`", "createdAt": None}], 1)
    assert p["branch"] is None and p["candidates"] == ["feature/gone"]


def test_pick_ready_note_pattern_skips_coordinator_notes_for_the_fallback(fx):
    fx.root.joinpath("c.json").write_text(json.dumps({"train": {"branchOwnership": "any", "notePattern": r"^\[coordinator\]"}}))
    cfg = T.load_config(fx.work, fx.root / "c.json")
    cs = [{"body": "READY from the worker", "createdAt": None}, {"body": "[coordinator] READY again please", "createdAt": None}]
    assert T.pick_ready(cfg, cs, 1)["body"] == "READY from the worker"


PREFLIGHT_BODY = ("READY `{b}` @ {sha} (enqueued from a host that does not gate: preflight only, no pre-check; the batch gate is the first full test).\n\n"
                  "```\n=== preflight (enqueue.sh): PASS === tree {sha} on origin/master 0123456789 === host h === 3s\n"
                  "PASS fetch   0s  origin/master at 0123456789\n=== preflight: PASS -- not gated on this host; the batch gate is the test ===\n```\nflag: none")


def preflight_body(fx, b, sha=None):
    """enqueue.sh's READY for branch <b>: it names the branch's tip (the real one unless a sha is given)."""
    return PREFLIGHT_BODY.format(b=b, sha=sha or T.short_tip(fx.cfg(), b))


def test_pick_ready_marks_a_preflight_ready_by_its_block_and_a_plain_one_as_ready(fx):
    fx.branch("feature/pf", {"pf.txt": "1\n"})
    cfg = fx.cfg()
    pf = T.pick_ready(cfg, [{"body": preflight_body(fx, "feature/pf"), "createdAt": None}], 1)
    assert (pf["branch"], pf["basis"]) == ("feature/pf", "preflight")
    plain = T.pick_ready(cfg, [{"body": "READY `feature/pf`, prebank PASS", "createdAt": None}], 1)
    assert plain["basis"] == "ready"
    failed = T.pick_ready(cfg, [{"body": preflight_body(fx, "feature/pf").replace(": PASS ===", ": FAIL ==="), "createdAt": None}], 1)
    assert failed["basis"] == "ready"   # only the PASS block is a preflight READY; a pasted FAIL block is a plain (and odd) READY


def test_preflight_pattern_is_configurable(fx):
    fx.root.joinpath("c.json").write_text(json.dumps({"train": {"branchOwnership": "any", "preflightPattern": r"PREFLIGHTED BY HAND"}}))
    cfg = T.load_config(fx.work, fx.root / "c.json")
    assert T.ready_basis(cfg, "READY `a/b` PREFLIGHTED BY HAND") == "preflight"
    assert T.ready_basis(cfg, preflight_body(fx, "a/b", "abc1234")) == "ready"


def test_queue_takes_a_preflight_ready_as_a_first_class_item_and_says_so(fx):
    """The READY enqueue.sh posts (a host that does not gate) is launchable like any other; its row carries
    basis `preflight`, its note says the batch gate is its first full test, the status line counts it, and
    the planner trains it; a non-launchable preflight item keeps its own state's note."""
    fx.branch("feature/pf", {"pf.txt": "1\n"})
    fx.branch("feature/plain", {"plain.txt": "1\n"})
    fx.branch("feature/pf-landed", {"pfl.txt": "1\n"})
    pf = fx.issue("pf"); fx.comment(pf, preflight_body(fx, "feature/pf"))
    plain = fx.ready("plain", "feature/plain")
    landed = fx.issue("pf-landed"); fx.comment(landed, preflight_body(fx, "feature/pf-landed"))
    fx.land("feature/pf-landed")
    q = fx.queue()
    assert (q[pf]["state"], q[pf]["basis"], q[pf]["note"]) == ("queue", "preflight", T.PREFLIGHT_NOTE)
    assert (q[plain]["state"], q[plain]["basis"], q[plain]["note"]) == ("queue", "ready", "-")
    assert (q[landed]["state"], q[landed]["basis"], q[landed]["note"]) == ("on-master", "preflight", "landing proof: ancestor")
    line = T.status_line(list(q.values()), when="W")
    assert "3 ready" in line and "| 2 preflight" in line
    out, fault = fx.plan(size=4)
    assert fault is None
    assert [k for k in kinds(out) if k[0] == "train"] == [("train", pf), ("train", plain)]
    assert any(r.startswith(f"train\t{pf}\tfeature/pf\t") and r.endswith(T.PREFLIGHT_NOTE) for r in out)


def test_pick_ready_is_none_without_a_ready_comment(fx):
    assert T.pick_ready(fx.cfg(), [{"body": "working on it", "createdAt": None}], 1) is None


# ── the queue ───────────────────────────────────────────────────────────────────────────
def test_queue_orders_first_then_lane_then_priority_then_age(fx):
    for i, b in enumerate("abcd"):
        fx.branch(f"feature/{b}", {f"{b}.txt": "1\n"})
    low = fx.ready("low", "feature/a", ("ready-for-review", "P3"))
    high = fx.ready("high", "feature/b", ("ready-for-review", "P0"))
    hot = fx.ready("hot", "feature/c", ("ready-for-review", "P3", "hotfix"))
    pinned = fx.ready("pinned", "feature/d", ("ready-for-review", "P3"))
    fx.cfg().overrides.parent.mkdir(parents=True, exist_ok=True)
    fx.cfg().overrides.write_text(f"first {pinned}\n")
    order = [r["issue"] for r in T.plan_queue(fx.cfg())]
    assert order == [pinned, hot, high, low]


def test_queue_requires_every_ready_label_and_a_ready_comment(fx):
    fx.branch("feature/a", {"a.txt": "1\n"})
    fx.ready("no second label", "feature/a")
    fx.root.joinpath("c.json").write_text(json.dumps({"train": {"branchOwnership": "any", "readyLabels": ["ready-for-review", "host:x"]}}))
    cfg = T.load_config(fx.work, fx.root / "c.json")
    assert T.plan_queue(cfg) == []
    quiet = fx.issue("labelled but never said READY")
    assert quiet not in {r["issue"] for r in T.plan_queue(fx.cfg())}


def test_queue_any_labels_takes_an_item_carrying_at_least_one_of_them(fx):
    """`anyLabels` is a scope ("at least one of"), beside `readyLabels` ("all of")."""
    for b in "abc":
        fx.branch(f"feature/{b}", {f"{b}.txt": "1\n"})
    mac = fx.ready("from the mac", "feature/a", ("ready-for-review", "host:mac"))
    linux = fx.ready("from the linux host", "feature/b", ("ready-for-review", "host:linux-a"))
    unscoped = fx.ready("no host label", "feature/c")
    fx.root.joinpath("c.json").write_text(json.dumps({"train": {"branchOwnership": "any", "anyLabels": ["host:linux-a", "host:mac"]}}))
    cfg = T.load_config(fx.work, fx.root / "c.json")
    assert cfg.any_labels == ["host:linux-a", "host:mac"]
    assert {r["issue"] for r in T.plan_queue(cfg)} == {mac, linux}
    fx.root.joinpath("one.json").write_text(json.dumps({"train": {"branchOwnership": "any", "anyLabels": ["host:mac"]}}))
    assert [r["issue"] for r in T.plan_queue(T.load_config(fx.work, fx.root / "one.json"))] == [mac]
    # no anyLabels: no scope, every READY is an item (the default is unchanged)
    assert fx.cfg().any_labels == []
    assert {r["issue"] for r in T.plan_queue(fx.cfg())} == {mac, linux, unscoped}


def test_queue_ready_states_lists_a_claimed_issue_when_configured(fx):
    """`readyStates` is the tracker states the queue lists. A tracker's `open` is its claimable queue, so
    with the default `["open"]` a READY on a claimed (`working`) issue is no item; `["open", "working"]`
    lists both, an issue under two states is one item, and an unknown state refuses to load."""
    fx.branch("feature/free", {"free.txt": "1\n"})
    fx.branch("feature/held", {"held.txt": "1\n"})
    free = fx.ready("free", "feature/free")
    held = fx.ready("held", "feature/held")
    sh(sys.executable, str(ISSUES_FILE), "claim", str(held), cwd=fx.work)   # working/ until it lands
    assert fx.cfg().ready_states == ["open"]
    assert [r["issue"] for r in T.plan_queue(fx.cfg())] == [free]
    fx.root.joinpath("both.json").write_text(json.dumps({"train": {"branchOwnership": "any", "readyStates": ["open", "working"]}}))
    cfg = T.load_config(fx.work, fx.root / "both.json")
    assert cfg.ready_states == ["open", "working"]
    assert {r["issue"] for r in T.plan_queue(cfg)} == {free, held}
    fx.root.joinpath("twice.json").write_text(json.dumps({"train": {"branchOwnership": "any", "readyStates": ["all", "open", "working"]}}))
    rows = T.plan_queue(T.load_config(fx.work, fx.root / "twice.json"))
    assert sorted(r["issue"] for r in rows) == sorted([free, held])   # once each
    fx.root.joinpath("typo.json").write_text(json.dumps({"train": {"branchOwnership": "any", "readyStates": ["open", "wroking"]}}))
    with pytest.raises(SystemExit, match=r"train\.readyStates in .*typo\.json .*wroking"):
        T.load_config(fx.work, fx.root / "typo.json")
    fx.root.joinpath("empty.json").write_text(json.dumps({"train": {"branchOwnership": "any", "readyStates": []}}))
    assert T.load_config(fx.work, fx.root / "empty.json").ready_states == ["open"]   # empty = the default


def test_queue_states(fx):
    fx.branch("feature/ok", {"ok.txt": "1\n"})
    fx.branch("feature/held", {"held.txt": "1\n"})
    fx.branch("feature/flying", {"flying.txt": "1\n"})
    fx.branch("feature/c1", {"README.md": "c1\n"})
    fx.branch("feature/c2", {"README.md": "c2\n"})
    fx.branch("feature/landed", {"landed.txt": "1\n"})
    ok = fx.ready("ok", "feature/ok")
    held = fx.ready("held", "feature/held")
    flying = fx.ready("flying", "feature/flying")
    gone = fx.ready("gone", "feature/never-pushed")
    onm = fx.ready("onm", "feature/landed")
    fx.land("feature/landed")
    c1 = fx.ready("c1", "feature/c1")
    cfg = fx.cfg()
    cfg.overrides.parent.mkdir(parents=True, exist_ok=True)
    cfg.overrides.write_text(f"# a comment\nhold {held} waiting on the owner\n")
    fx.land("feature/c1")   # c2 now conflicts with master in README.md
    c2 = fx.ready("c2", "feature/c2")
    q = fx.queue(in_flight=[flying])
    assert q[ok]["state"] == "queue"
    assert (q[held]["state"], q[held]["note"]) == ("hold", "waiting on the owner")
    assert q[flying]["state"] == "in-flight"
    assert (q[gone]["state"], q[gone]["note"]) == ("no-branch", "feature/never-pushed")
    assert q[onm]["state"] == "on-master"
    assert q[c1]["state"] == "on-master"
    assert q[c2]["state"] == "conflict" and "README.md" in q[c2]["note"] and "prefilter" in q[c2]["note"]


def test_landing_proof_names_how_master_carries_a_branch(fx):
    cfg = fx.cfg()
    fx.branch("feature/merged", {"a.txt": "1\n"})
    fx.land("feature/merged")
    fx.branch("feature/rebased", {"b.txt": "1\n"})
    fx.commit_on("master", {"m.txt": "1\n"})   # master moved, so the rebase rewrites the commit
    fx.land("feature/rebased", how="rebase")
    fx.branch("feature/squashed", {"c.txt": "1\n"})
    fx.commit_on("feature/squashed", {"d.txt": "1\n"})
    fx.land("feature/squashed", how="squash")
    fx.branch("feature/open", {"e.txt": "1\n"})
    assert T.landing_proof(cfg, "origin/feature/merged") == "ancestor"
    assert T.landing_proof(cfg, "origin/feature/rebased") == "patch"
    assert T.landing_proof(cfg, "origin/feature/squashed") == "content"
    assert T.landing_proof(cfg, "origin/feature/open") == ""
    fx.commit_on("master", {"README.md": "edited after the landings\n"})
    assert T.landing_proof(cfg, "origin/feature/squashed") == "content"   # a later landing elsewhere does not unland it
    fx.commit_on("master", {"c.txt": None}, "revert part of the squash")
    assert T.landing_proof(cfg, "origin/feature/squashed") == ""          # its work is no longer all there


def test_queue_reads_a_squash_landed_branch_as_on_master_and_a_planner_never_retakes_it(fx):
    fx.branch("feature/sq", {"s.txt": "1\n"})
    fx.commit_on("feature/sq", {"t.txt": "1\n"})
    n = fx.ready("sq", "feature/sq")
    fx.land("feature/sq", how="squash")
    q = fx.queue()
    assert (q[n]["state"], q[n]["note"]) == ("on-master", "landing proof: content")
    out, fault = fx.plan()
    assert fault is None and not [r for r in out if r.startswith("train\t")]


def test_launched_tip_is_not_queued_again_until_retry_or_a_new_tip(fx):
    fx.branch("feature/a", {"a.txt": "1\n"})
    n = fx.ready("a", "feature/a")
    cfg = fx.cfg()
    cfg.launched.parent.mkdir(parents=True, exist_ok=True)
    tip = T.short_tip(cfg, "feature/a")
    cfg.launched.write_text(f"{n} {tip} 2026-11-21T00:00Z rc=0\n")
    assert fx.queue()[n]["state"] == "launched"
    cfg.overrides.write_text(f"retry {n}\n")
    assert fx.queue()[n]["state"] == "queue"
    cfg.overrides.write_text("")
    fx.branch("feature/a", {"a.txt": "2\n"})
    assert fx.queue()[n]["state"] == "queue"


def test_train_state_holds_and_dropped_tips(fx):
    fx.branch("feature/a", {"a.txt": "1\n"})
    fx.branch("feature/b", {"b.txt": "1\n"})
    a, b = fx.ready("a", "feature/a"), fx.ready("b", "feature/b")
    cfg = fx.cfg()
    cfg.state_dir.mkdir(parents=True, exist_ok=True)
    (cfg.state_dir / "current.tsv").write_text(f"{a}\tfeature/a\tx\n")
    (cfg.state_dir / "dropped.tsv").write_text(f"{b}\t{T.short_tip(cfg, 'feature/b')}\t2026\twhy\n")
    q = fx.queue()
    assert q[a]["state"] == "in-train" and q[b]["state"] == "train-dropped"


def test_classify_limit_skips_the_merge_check_after_enough_launchable_items(fx):
    for b in "abc":
        fx.branch(f"feature/{b}", {f"{b}.txt": "1\n"})
    ns = [fx.ready(b, f"feature/{b}") for b in "abc"]
    fx.root.joinpath("c.json").write_text(json.dumps({"train": {"branchOwnership": "any", "classifyLimit": 1}}))
    q = {r["issue"]: r["state"] for r in T.plan_queue(T.load_config(fx.work, fx.root / "c.json"))}
    assert q[ns[0]] == "queue" and q[ns[1]] == "unchecked" and q[ns[2]] == "unchecked"


def test_status_line_counts_states_and_names_the_next_item(fx):
    fx.branch("feature/a", {"a.txt": "1\n"})
    a = fx.ready("a", "feature/a")
    gone = fx.ready("gone", "feature/nope")
    line = T.status_line(T.plan_queue(fx.cfg()), when="W")
    assert f"W merge-train: 2 ready | next #{a} feature/a @" in line and f"1 no-branch (#{gone})" in line


# ── the planner ─────────────────────────────────────────────────────────────────────────
def kinds(rows):
    return [(r.split("\t")[0], int(r.split("\t")[1])) for r in rows]


def test_planner_takes_the_next_candidate_when_one_conflicts_and_fills_the_size(fx):
    fx.branch("feature/a", {"README.md": "from a\n"})
    fx.branch("feature/b", {"README.md": "from b\n"})   # conflicts with a, in a path no driver owns
    fx.branch("feature/c", {"c.txt": "1\n"})
    fx.branch("feature/d", {"d.txt": "1\n"})
    a, b, c, d = (fx.ready(x, f"feature/{x}") for x in "abcd")
    rows, fault = fx.plan(size=3)
    assert fault is None
    assert kinds(rows) == [("train", a), ("skip", b), ("train", c), ("train", d)]
    skip = next(r for r in rows if r.startswith("skip"))
    assert "README.md" in skip and "prefilter" in skip


def test_planner_stops_at_the_size_limit(fx):
    for x in "abc":
        fx.branch(f"feature/{x}", {f"{x}.txt": "1\n"})
    ns = [fx.ready(x, f"feature/{x}") for x in "abc"]
    rows, _ = fx.plan(size=2)
    assert kinds(rows) == [("train", ns[0]), ("train", ns[1])]


def test_planner_judges_each_candidate_against_the_train_so_far(fx):
    fx.branch("feature/a", {"shared.txt": "a\n"})
    fx.branch("feature/b", {"shared.txt": "b\n"})   # fine against master, conflicts once a is in
    a, b = fx.ready("a", "feature/a"), fx.ready("b", "feature/b")
    rows, _ = fx.plan()
    assert kinds(rows) == [("train", a), ("skip", b)]
    assert "train so far" in rows[1]


def test_a_stack_lands_at_its_tip_and_a_lower_slice_rides_as_a_member_without_a_merge(fx):
    fx.branch("feature/s1", {"s1.txt": "1\n"})
    fx.branch("feature/s2", {"s2.txt": "1\n"}, base="feature/s1")
    top = fx.ready("top", "feature/s2")
    low = fx.ready("low", "feature/s1")
    # the stack's tip is queued first (older issue number is `top`); the lower slice is carried by it
    rows, fault = fx.plan()
    assert fault is None
    assert kinds(rows) == [("train", top), ("train", low)]
    assert "carried by an earlier member" in rows[1]


def test_a_failed_driver_owned_merge_is_cleared_before_the_next_candidate(fx):
    fx.branch("feature/a", {"data.bin": "A\n"})
    fx.branch("feature/b", {"data.bin": "B\n"})   # data.bin is merge=binary: owned by a driver, still conflicts
    fx.branch("feature/c", {"c.txt": "1\n"})
    a, b, c = (fx.ready(x, f"feature/{x}") for x in "abc")
    rows, fault = fx.plan()
    assert fault is None
    assert kinds(rows) == [("train", a), ("skip", b), ("train", c)]
    assert "data.bin" in rows[1]
    # the scratch holds no half-merge for whoever plans next
    assert T.git(fx.cfg().scratch, "status", "--porcelain").stdout.strip() == ""


def test_union_driver_paths_merge_clean_in_the_train(fx):
    fx.branch("feature/a", {"registry.txt": "a\nrow-a\n"})
    fx.branch("feature/b", {"registry.txt": "a\nrow-b\n"})
    a, b = fx.ready("a", "feature/a"), fx.ready("b", "feature/b")
    rows, _ = fx.plan()
    assert kinds(rows) == [("train", a), ("train", b)]


def test_a_dropped_tip_is_skipped_until_it_is_rebanked(fx):
    fx.branch("feature/a", {"a.txt": "1\n"})
    a = fx.ready("a", "feature/a")
    cfg = fx.cfg()
    cfg.state_dir.mkdir(parents=True, exist_ok=True)
    rows = T.plan_queue(cfg)
    (cfg.state_dir / "dropped.tsv").write_text(f"{a}\t{rows[0]['tip']}\t2026\tx\n")
    out, _ = T.plan_train(cfg, [{**rows[0], "state": "queue"}])   # force it past the queue's own train-dropped state
    assert out == [f"skip\t{a}\tfeature/a\tdropped from a train at this tip; re-bank to offer it again"]


def test_merge_fault_hook_drops_a_candidate_whose_generator_failed(fx):
    fx.root.joinpath("c.json").write_text(json.dumps({"train": {"branchOwnership": "any", "hooks": {"mergeFault": "printf 'generator-failed\\tgen died on %s\\n' \"$(head -1)\""}}}))
    fx.branch("feature/a", {"data.bin": "A\n"})
    fx.branch("feature/b", {"data.bin": "B\n"})
    fx.branch("feature/c", {"c.txt": "1\n"})
    a, b, c = (fx.ready(x, f"feature/{x}") for x in "abc")
    cfg = T.load_config(fx.work, fx.root / "c.json")
    rows, fault = T.plan_train(cfg, T.plan_queue(cfg))
    assert fault is None
    assert kinds(rows) == [("train", a), ("drop", b), ("train", c)]
    assert "gen died on data.bin" in rows[1]


def test_merge_fault_hook_driver_fault_is_the_planners_fault_not_the_branchs(fx):
    fx.root.joinpath("c.json").write_text(json.dumps({"train": {"branchOwnership": "any", "hooks": {"mergeFault": "printf 'driver-fault\\tno toolchain\\n'"}}}))
    fx.branch("feature/a", {"data.bin": "A\n"})
    fx.branch("feature/b", {"data.bin": "B\n"})
    fx.ready("a", "feature/a"); b = fx.ready("b", "feature/b")
    cfg = T.load_config(fx.work, fx.root / "c.json")
    rows, fault = T.plan_train(cfg, T.plan_queue(cfg))
    assert f"#{b}" in fault and "no toolchain" in fault
    assert not any(r.startswith(("skip", "drop")) and f"\t{b}\t" in r for r in rows)


def test_prepare_scratch_hook_failure_stops_the_plan_with_a_named_fault(fx):
    fx.root.joinpath("c.json").write_text(json.dumps({"train": {"branchOwnership": "any", "hooks": {"prepareScratch": "echo toolchain broken >&2; exit 4"}}}))
    fx.branch("feature/a", {"a.txt": "1\n"})
    fx.ready("a", "feature/a")
    cfg = T.load_config(fx.work, fx.root / "c.json")
    rows, fault = T.plan_train(cfg, T.plan_queue(cfg))
    assert rows == [] and "prepareScratch exited 4" in fault and "toolchain broken" in fault


def test_seed_dirs_are_hardlink_copies_and_reseeded_when_the_marker_changes(fx):
    fx.root.joinpath("c.json").write_text(json.dumps({"train": {"branchOwnership": "any", "seedDirs": ["deps"], "seedMarker": "stamp"}}))
    deps = fx.work / "deps"
    deps.mkdir()
    (deps / "stamp").write_text("1")
    (deps / "lib.txt").write_text("lib")
    cfg = T.load_config(fx.work, fx.root / "c.json")
    scratch = T.scratch_prepare(cfg)
    assert T.seed_scratch(cfg, scratch) == []
    assert os.stat(scratch / "deps/lib.txt").st_ino == os.stat(deps / "lib.txt").st_ino   # hardlinked, no bytes
    (deps / "stamp").unlink(); (deps / "stamp").write_text("2")   # a reinstall: a new inode
    T.seed_scratch(cfg, scratch)
    assert os.stat(scratch / "deps/stamp").st_ino == os.stat(deps / "stamp").st_ino
    # a missing source is named, not silent
    shutil_rm = __import__("shutil").rmtree
    shutil_rm(deps)
    assert "deps is not present" in T.seed_scratch(cfg, scratch)[0]



# ── the planner's merges run hooks off; the probe is timed ──────────────────────────────
def install_post_merge_hook(fx, marker):
    """A repository post-merge hook that appends a line to <marker>, shared by every worktree of the repo."""
    hooks = fx.root / "hooks"
    hooks.mkdir()
    (hooks / "post-merge").write_text(f"#!/bin/sh\necho hook >> '{marker}'\n")
    (hooks / "post-merge").chmod(0o755)
    sh("git", "config", "core.hooksPath", str(hooks), cwd=fx.work)


def test_the_planner_merges_with_hooks_off_so_a_post_merge_hook_never_runs_per_candidate(fx):
    fx.branch("feature/a", {"a.txt": "a\n"})
    fx.branch("feature/b", {"b.txt": "b\n"})
    fx.branch("feature/c", {"c.txt": "c\n"})
    marker = fx.root / "hook-marker"
    install_post_merge_hook(fx, marker)
    # The hook is live: a plain merge in the work tree fires it once.
    sh("git", "checkout", "-q", "-B", "probe", "origin/master", cwd=fx.work)
    sh("git", "merge", "--no-ff", "-q", "-m", "probe", "origin/feature/a", cwd=fx.work)
    assert marker.read_text().split() == ["hook"]
    marker.unlink()
    sh("git", "checkout", "-q", "master", cwd=fx.work)
    for b in ("feature/a", "feature/b", "feature/c"):
        fx.ready(b, b)
    out, fault = fx.plan(size=3)
    assert fault is None
    assert [ln.split("\t")[2] for ln in out if ln.startswith("train\t")] == ["feature/a", "feature/b", "feature/c"]
    assert not marker.exists(), "the planner's candidate merges ran the repository's post-merge hook"


def test_plan_train_reports_each_candidate_s_verdict_and_seconds(fx):
    fx.branch("feature/a", {"a.txt": "a\n"})
    fx.branch("feature/b", {"a.txt": "b\n"})   # clean onto master, conflicts with feature/a on the train so far
    fx.branch("feature/c", {"c.txt": "c\n"})
    issues = [fx.ready(b, b) for b in ("feature/a", "feature/b", "feature/c")]
    seen = []
    cfg = fx.cfg()
    out, fault = T.plan_train(cfg, T.plan_queue(cfg), 3, on_candidate=lambda i, k, s: seen.append((i, k, s)))
    assert fault is None
    assert [(i, k) for i, k, _ in seen] == [(issues[0], "train"), (issues[1], "skip"), (issues[2], "train")]
    assert all(isinstance(s, float) and s >= 0 for _, _, s in seen)
    assert sum(1 for ln in out if ln.startswith("train\t")) == 2

# ── reopen ──────────────────────────────────────────────────────────────────────────────
def test_reopen_when_the_newest_ready_names_a_branch_the_landing_did_not_carry(fx):
    fx.branch("feature/lower", {"lower.txt": "1\n"})
    fx.branch("feature/upper", {"upper.txt": "1\n"}, base="feature/lower")
    n = fx.ready("stack", "feature/lower")
    fx.land("feature/lower")
    landed = T.git(fx.work, "rev-parse", "origin/master").stdout.strip()
    sh(sys.executable, str(ISSUES_FILE), "close", str(n), cwd=fx.work)
    fx.comment(n, "READY on `feature/upper`")
    cfg = fx.cfg()
    assert T.reopen_if_newer_ready(cfg, n, "feature/lower", landed) is True
    issue = json.loads(T.tracker(cfg, "issue_get", str(n)).stdout)
    assert issue["state"] == "OPEN"
    assert "ready-for-review" in [lb["name"] for lb in issue["labels"]]
    assert "feature/upper" in issue["body"] and "reopened" in issue["body"]


def test_no_reopen_when_the_newest_ready_is_the_landed_branch_or_already_carried(fx):
    fx.branch("feature/lower", {"lower.txt": "1\n"})
    n = fx.ready("one", "feature/lower")
    fx.land("feature/lower")
    landed = T.git(fx.work, "rev-parse", "origin/master").stdout.strip()
    sh(sys.executable, str(ISSUES_FILE), "close", str(n), cwd=fx.work)
    cfg = fx.cfg()
    assert T.newer_ready(cfg, n, "feature/lower", landed) is None
    fx.branch("feature/other", {"x.txt": "1\n"}, base="master")
    fx.comment(n, "READY `feature/lower`")   # the same branch again: still carried
    assert T.newer_ready(cfg, n, "feature/other", landed) is None   # its tip is an ancestor of the landing


def test_same_branch_ready_after_launch_reopens_when_timestamps_exist(fx):
    fx.branch("feature/a", {"a.txt": "1\n"})
    n = fx.ready("a", "feature/a")
    cfg = fx.cfg()
    landed = T.git(fx.work, "rev-parse", "origin/master").stdout.strip()   # the branch's new commit is NOT in it
    assert T.newer_ready(cfg, n, "feature/a", landed, launched="2000-01-01T00:00:00Z")["branch"] == "feature/a"
    assert T.newer_ready(cfg, n, "feature/a", landed, launched="2999-01-01T00:00:00Z") is None


# ── the CLI ─────────────────────────────────────────────────────────────────────────────
def test_cli_queue_and_plan_and_reopen(fx):
    fx.branch("feature/a", {"a.txt": "1\n"})
    a = fx.ready("a", "feature/a")
    base = [sys.executable, str(CLI), "--repo", str(fx.work)]
    q = sh(*base, "queue", "--status-line")
    assert q.stdout.splitlines()[0].count("merge-train: 1 ready") == 1
    assert q.stdout.splitlines()[1].split("\t")[:3] == ["1", "queue", str(a)]
    assert q.stdout.splitlines()[1].split("\t")[8] == "ready"   # the basis column: `ready`, or `preflight` for enqueue.sh's READY
    p = sh(*base, "plan", "--size", "2")
    assert p.stdout.startswith(f"train\t{a}\tfeature/a\t")
    r = sh(*base, "reopen", "--issue", str(a), "--member-branch", "feature/a", "--landed", "origin/master")
    assert r.stdout.strip() == "not reopened"


def test_cli_plan_exits_2_with_the_fault_when_the_planner_cannot_be_trusted(fx):
    fx.work.joinpath(".autocoder.json").write_text(json.dumps({"issueSource": "file", "issueDir": str(fx.issues),
                                                                "train": {"hooks": {"prepareScratch": "exit 9"}}}))
    fx.branch("feature/a", {"a.txt": "1\n"})
    fx.ready("a", "feature/a")
    r = sh(sys.executable, str(CLI), "--repo", str(fx.work), "plan", check=False)
    assert r.returncode == 2 and "fault\tthe scratch toolchain is not working" in r.stdout


def test_cli_reports_a_failed_fetch_with_the_remote_and_the_repo(tmp_path):
    f = Fixture(tmp_path)
    sh("git", "remote", "set-url", "origin", str(tmp_path / "missing.git"), cwd=f.work)
    r = sh(sys.executable, str(CLI), "--repo", str(f.work), "queue", check=False)
    assert r.returncode == 1 and "git fetch origin failed" in r.stderr and str(f.work) in r.stderr


# ── regenerate-only: a change to regenerated files alone lands nothing and is never planned ──────
def test_a_branch_changing_only_regenerated_paths_is_regenerate_only_and_never_planned(tmp_path):
    fx = Fixture(tmp_path, {"regeneratedMergeDrivers": ["regen", "keep-ours"], "regeneratedAdvice": "Land the change in the source instead."})
    fx.commit_on("master", {".gitattributes": "registry.txt merge=union\ndata.bin merge=binary\ngen/* merge=regen\nexport.lock merge=keep-ours\n",
                            "gen/a.txt": "0\n", "gen/b.txt": "0\n", "export.lock": "0\n"}, message="generated files")
    fx.branch("feature/gen-only", {"gen/a.txt": "1\n", "export.lock": "1\n"})
    fx.branch("feature/gen-and-source", {"gen/b.txt": "1\n", "src.txt": "1\n"})
    fx.branch("feature/attrs-too", {"gen/a.txt": "2\n", ".gitattributes": "gen/* merge=regen\n"})
    gen_only = fx.ready("gen only", "feature/gen-only")
    mixed = fx.ready("gen and source", "feature/gen-and-source")
    attrs = fx.ready("attrs too", "feature/attrs-too")
    q = fx.queue()
    assert q[gen_only]["state"] == "regenerate-only"
    assert "`gen/a.txt`" in q[gen_only]["note"] and "`export.lock`" in q[gen_only]["note"]
    assert "would land nothing. Land the change in the source instead." in q[gen_only]["note"]
    assert q[mixed]["state"] == "queue" and q[attrs]["state"] == "queue"     # a source, or the attributes file itself, is a real change
    rows, fault = fx.plan()
    assert fault is None
    assert [r.split("\t")[:2] for r in rows] == [["skip", str(gen_only)], ["train", str(mixed)], ["train", str(attrs)]]
    assert rows[0].split("\t")[3].startswith("regenerate-only: changes only regenerated files")
    assert "1 regenerate-only" in T.status_line(list(q.values()))


def test_regenerate_only_needs_a_configured_driver_and_reads_the_integration_branch_s_attributes(fx):
    fx.commit_on("master", {".gitattributes": "gen/* merge=regen\n", "gen/a.txt": "0\n"}, message="generated files")
    fx.branch("feature/gen-only", {"gen/a.txt": "1\n"})
    n = fx.ready("gen only", "feature/gen-only")
    assert fx.queue()[n]["state"] == "queue"                                   # no regeneratedMergeDrivers: not classified
    cfg = fx.cfg()
    cfg.regenerated_drivers = ["regen"]
    assert T.regenerate_only(cfg, cfg.remote_ref("feature/gen-only")) == ["gen/a.txt"]
    # The attributes are the integration branch's, not the checkout's: a working tree without the row still classifies.
    (fx.work / ".gitattributes").write_text("")
    assert T.regenerate_only(cfg, cfg.remote_ref("feature/gen-only")) == ["gen/a.txt"]
    sh("git", "checkout", "-q", ".gitattributes", cwd=fx.work)
    assert T.regenerate_only(cfg, cfg.ref) is None                            # nothing changed: not this


# ── the READY's named sha and the branch's current tip (readyTip) ──────────────────────
def rebase_onto_master(fx, name):
    """Rebase <name> onto origin/master and force-push it (the worker's move after a sibling lands)."""
    sh("git", "checkout", "-q", "-B", name, f"origin/{name}", cwd=fx.work)
    sh("git", "rebase", "-q", "origin/master", cwd=fx.work)
    sh("git", "push", "-q", "-f", "origin", name, cwd=fx.work)
    sh("git", "checkout", "-q", "master", cwd=fx.work)
    sh("git", "fetch", "-q", "origin", cwd=fx.work)


def merge_master_into(fx, name):
    """Merge origin/master into <name> (a fast-forward of the branch by a merge commit) and push."""
    sh("git", "checkout", "-q", "-B", name, f"origin/{name}", cwd=fx.work)
    sh("git", "merge", "-q", "--no-ff", "-m", "merge master", "origin/master", cwd=fx.work)
    sh("git", "push", "-q", "origin", name, cwd=fx.work)
    sh("git", "checkout", "-q", "master", cwd=fx.work)
    sh("git", "fetch", "-q", "origin", cwd=fx.work)


def ready_at(fx, title, branch, sha=None, extra=""):
    """A READY that names the branch AND its tip, as enqueue.sh and a prebank block do."""
    n = fx.issue(title)
    fx.comment(n, f"READY `{branch}` @ {sha or T.short_tip(fx.cfg(), branch)}{extra}")
    return n


def test_named_tip_reads_the_first_sha_after_the_branch_on_its_line():
    assert T.named_tip("READY `feature/x` @ abc1234, rebased onto origin/master deadbee12 (prebank 5s)", "feature/x") == "abc1234"
    assert T.named_tip("READY `feature/x` @ `0123456789abcdef0123456789abcdef01234567`", "feature/x") == "0123456789abcdef0123456789abcdef01234567"
    assert T.named_tip("re-READY on `origin/feature/x` at 9f41624fee on master 0924702650", "feature/x") == "9f41624fee"
    assert T.named_tip("READY on `feature/x`", "feature/x") is None                      # no sha: today's rule
    assert T.named_tip("READY `feature/x`\ntree abc1234 on origin/master", "feature/x") is None   # another line is not this branch's tip
    assert T.named_tip("READY `feature/x-2` @ abc1234", "feature/x") is None             # another branch's name
    assert T.named_tip("READY `feature/x` @ abcdef (short)", "feature/x") is None        # 6 digits is not a sha
    assert T.named_tip("READY `feature/x`: abc1234 banked", "feature/x") == "abc1234"
    assert T.named_tip("READY `feature/x` at abc1234", "feature/x") == "abc1234"
    # Only the sha joined to the branch counts; anything else on the line fails open to the current tip, never to a refusal
    assert T.named_tip("READY `feature/a` (stacked on `feature/b` @ bbbbbbb1) @ aaaaaaa1", "feature/a") is None
    assert T.named_tip("READY `feature/x` CI run 19567890123 green @ abc1234", "feature/x") is None
    assert T.named_tip("READY `feature/x` @ 20261121T20 abc1234", "feature/x") is None


def test_queue_follows_a_rebased_tip_that_carries_the_readys_patches_and_says_so(fx):
    """The worker posts READY naming the tip, a sibling lands, the worker rebases and force-pushes: the queue
    classifies the NEW tip (same patches, another base), the row says which tip it took and why, and the
    planner trains it. No second READY is needed."""
    fx.branch("feature/rb", {"rb.txt": "1\n"})
    fx.branch("feature/sibling", {"README.md": "sibling\n"})
    old = T.short_tip(fx.cfg(), "feature/rb")
    rb = ready_at(fx, "rb", "feature/rb")
    fx.land("feature/sibling")
    rebase_onto_master(fx, "feature/rb")
    new = T.short_tip(fx.cfg(), "feature/rb")
    assert new != old
    q = fx.queue()
    assert (q[rb]["state"], q[rb]["tip"], q[rb]["named"]) == ("queue", new, old)
    assert q[rb]["note"] == q[rb]["followed"] == f"READY named `{old}`, taking the rebased tip `{new}`: same patches"
    out, fault = fx.plan()
    assert fault is None and kinds(out) == [("train", rb)]
    assert any(r.startswith(f"train\t{rb}\tfeature/rb\t{new}\t") for r in out)


def test_queue_follows_a_fast_forwarded_tip_and_a_conflict_resolved_rebase_is_other_work(fx):
    fx.branch("feature/ff", {"ff.txt": "1\n"})
    fx.branch("feature/cr", {"README.md": "cr\n"})
    fx.branch("feature/sibling", {"README.md": "sibling\n"})
    ff_old, cr_old = T.short_tip(fx.cfg(), "feature/ff"), T.short_tip(fx.cfg(), "feature/cr")
    ff = ready_at(fx, "ff", "feature/ff")
    cr = ready_at(fx, "cr", "feature/cr")
    fx.land("feature/sibling")
    merge_master_into(fx, "feature/ff")                          # a merge commit: the named sha is in the tip's history
    # cr's own line conflicts with the sibling's: the rebase resolves it, which changes cr's patch
    sh("git", "checkout", "-q", "-B", "feature/cr", "origin/feature/cr", cwd=fx.work)
    sh("git", "rebase", "origin/master", cwd=fx.work, check=False)
    (fx.work / "README.md").write_text("sibling and cr\n")
    sh("git", "add", "README.md", cwd=fx.work)
    sh("git", "-c", "core.editor=true", "rebase", "--continue", cwd=fx.work)
    sh("git", "push", "-q", "-f", "origin", "feature/cr", cwd=fx.work)
    sh("git", "checkout", "-q", "master", cwd=fx.work)
    sh("git", "fetch", "-q", "origin", cwd=fx.work)
    q = fx.queue()
    ff_new, cr_new = T.short_tip(fx.cfg(), "feature/ff"), T.short_tip(fx.cfg(), "feature/cr")
    assert q[ff]["state"] == "queue" and q[ff]["followed"] == f"READY named `{ff_old}`, taking the fast-forwarded tip `{ff_new}`: same patches"
    assert q[cr]["state"] == "tip-moved" and q[cr]["followed"] == ""
    assert q[cr]["note"] == (f"the tip `{cr_new}` carries work the READY at `{cr_old}` did not name (the patches differ); "
                             "re-post READY at this tip (a rebase or fast-forward of the same patches is taken without one)")
    assert "1 tip-moved" in T.status_line(list(q.values()))


def test_a_tip_with_a_new_commit_is_tip_moved_until_a_ready_names_it(fx):
    fx.branch("feature/nw", {"nw.txt": "1\n"})
    old = T.short_tip(fx.cfg(), "feature/nw")
    nw = ready_at(fx, "nw", "feature/nw")
    fx.commit_on("feature/nw", {"nw.txt": "2\n"}, message="a fix nobody banked")
    new = T.short_tip(fx.cfg(), "feature/nw")
    q = fx.queue()
    assert (q[nw]["state"], q[nw]["tip"], q[nw]["named"]) == ("tip-moved", new, old)
    out, fault = fx.plan()
    assert fault is None and kinds(out) == [("skip", nw)] and "tip-moved" in out[0]
    fx.comment(nw, f"READY `feature/nw` @ {new} (prebank PASS)")      # the owner banks the new tip
    q = fx.queue()
    assert (q[nw]["state"], q[nw]["named"], q[nw]["note"]) == ("queue", new, "-")


def test_a_ready_naming_no_sha_or_ready_tip_current_takes_whatever_tip_the_branch_has(tmp_path):
    fx = Fixture(tmp_path)
    fx.branch("feature/plain", {"p.txt": "1\n"})
    plain = fx.ready("plain", "feature/plain")                                    # "READY on `feature/plain`": no sha
    fx.commit_on("feature/plain", {"p.txt": "2\n"})
    fx.branch("feature/named", {"n.txt": "1\n"})
    named = ready_at(fx, "named", "feature/named")
    fx.commit_on("feature/named", {"n.txt": "2\n"})
    q = fx.queue()
    assert (q[plain]["state"], q[plain]["named"], q[plain]["note"]) == ("queue", "-", "-")
    assert q[named]["state"] == "tip-moved"
    cfg = json.loads((fx.work / ".autocoder.json").read_text())
    cfg["train"]["readyTip"] = "current"
    (fx.work / ".autocoder.json").write_text(json.dumps(cfg))
    q = fx.queue()
    assert (q[named]["state"], q[named]["note"], q[named]["followed"]) == ("queue", "-", "")   # the named sha is not consulted
    cfg["train"]["readyTip"] = "latest"
    (fx.work / ".autocoder.json").write_text(json.dumps(cfg))
    with pytest.raises(SystemExit, match=r"train\.readyTip in .*\.autocoder\.json must be one of \['named', 'current'\]; got 'latest'"):
        fx.cfg()


def test_a_base_sha_names_no_tip_and_an_unknown_sha_is_noted_but_the_tip_is_taken(fx):
    fx.branch("feature/b", {"b.txt": "1\n"})
    master = T.git(fx.work, "rev-parse", "--short=10", "origin/master").stdout.strip()
    tip = T.short_tip(fx.cfg(), "feature/b")
    base = ready_at(fx, "base", "feature/b", sha=master)         # the READY line names the base it was rebased onto, not the tip
    fx.branch("feature/u", {"u.txt": "1\n"})
    unknown = ready_at(fx, "unknown", "feature/u", sha="abc1234abc")
    q = fx.queue()
    assert (q[base]["state"], q[base]["note"], q[base]["named"]) == ("queue", "-", master)
    assert q[unknown]["state"] == "queue" and q[unknown]["followed"] == ""
    assert q[unknown]["note"] == f"READY names `abc1234abc`, which this clone cannot resolve; taking the branch's current tip `{T.short_tip(fx.cfg(), 'feature/u')}`"
    assert T.tip_relation(fx.cfg(), "feature/b", tip) == ("same", T.git(fx.work, "rev-parse", "origin/feature/b").stdout.strip())


def test_a_preflight_ready_keeps_its_note_beside_the_followed_tip_note(fx):
    fx.branch("feature/pf2", {"pf2.txt": "1\n"})
    fx.branch("feature/sibling", {"README.md": "sibling\n"})
    old = T.short_tip(fx.cfg(), "feature/pf2")
    pf = fx.issue("pf2"); fx.comment(pf, preflight_body(fx, "feature/pf2"))
    fx.land("feature/sibling")
    rebase_onto_master(fx, "feature/pf2")
    q = fx.queue()
    assert q[pf]["state"] == "queue" and q[pf]["basis"] == "preflight"
    assert q[pf]["note"] == f"{T.PREFLIGHT_NOTE}; READY named `{old}`, taking the rebased tip `{T.short_tip(fx.cfg(), 'feature/pf2')}`: same patches"


def test_the_trains_own_comments_are_never_readys(fx):
    """A told-once comment (`tip-moved`, a drop) quotes the branch, its tip and the word READY; read as a READY
    it would name the very tip the queue refused. Every tracker write of the train starts with `<swarm>: `."""
    fx.branch("feature/own", {"own.txt": "1\n"})
    old = T.short_tip(fx.cfg(), "feature/own")
    n = ready_at(fx, "own", "feature/own")
    fx.commit_on("feature/own", {"own.txt": "2\n"})
    new = T.short_tip(fx.cfg(), "feature/own")
    fx.comment(n, f"merge-train: not trained, `tip-moved`: `feature/own` @ `{new}`: re-post READY at this tip")
    q = fx.queue()
    assert (q[n]["state"], q[n]["named"]) == ("tip-moved", old)
    picked = T.pick_ready(fx.cfg(), [{"body": "[swarm] train: READY `feature/own` (another prefix: a worker's words)", "createdAt": None}], 1)
    assert picked is not None and picked["branch"] == "feature/own"
    assert T.pick_ready(fx.cfg(), [{"body": "[swarm] train: landed `feature/own`, post READY elsewhere", "createdAt": None}], 1) is None   # mentions READY after a branch: no READY
    cfg = json.loads((fx.work / ".autocoder.json").read_text()); cfg["train"]["swarm"] = "[swarm] train"
    (fx.work / ".autocoder.json").write_text(json.dumps(cfg))
    fx.branch("feature/own2", {"own2.txt": "1\n"})
    old2 = T.short_tip(fx.cfg(), "feature/own2")
    n2 = ready_at(fx, "own2", "feature/own2")
    fx.commit_on("feature/own2", {"own2.txt": "2\n"})
    fx.comment(n2, f"[swarm] train: dropped at planning: `feature/own2` @ `{T.short_tip(fx.cfg(), 'feature/own2')}`: a reason. Fix, push, post READY")
    assert (fx.queue()[n2]["state"], fx.queue()[n2]["named"]) == ("tip-moved", old2)   # the configured prefix is skipped too


# ── READY rows for the landing ledger ───────────────────────────────────────────────────
def test_ledger_ts_normalises_a_trackers_comment_time_to_the_ledgers_shape():
    assert T.ledger_ts("2026-11-22T01:02:03Z") == "2026-11-22T01:02:03Z"
    assert T.ledger_ts("2026-11-22T01:02:03.123+02:00") == "2026-11-21T23:02:03Z"   # an offset and a fraction (ADO, Jira)
    assert T.ledger_ts("2026-11-22T01:02:00Z") == "2026-11-22T01:02:00Z"
    assert T.ledger_ts("") is None and T.ledger_ts(None) is None and T.ledger_ts("yesterday") is None


def test_a_ready_is_noted_once_per_issue_and_comment_time_with_the_comments_time(fx):
    cfg = fx.cfg()
    written = []
    rows = [{"issue": 5, "readyAt": "2026-11-22T01:00:00Z", "state": "queue"},
            {"issue": 6, "readyAt": "2026-11-22T01:05:00Z", "state": "no-branch"},   # a READY naming nothing still starts the wait
            {"issue": 7, "readyAt": "", "state": "queue"}]                             # a backend with no comment time: nothing to stamp
    assert T.note_readys(cfg, rows, lambda i, ts: written.append((i, ts))) == [5, 6]
    assert written == [(5, "2026-11-22T01:00:00Z"), (6, "2026-11-22T01:05:00Z")]
    assert T.note_readys(cfg, rows, lambda i, ts: written.append((i, ts))) == []         # the same READYs: nothing new
    rows[0]["readyAt"] = "2026-11-22T02:00:00Z"                                          # a re-bank is a new comment
    assert T.note_readys(cfg, rows, lambda i, ts: written.append((i, ts))) == [5]
    assert written[-1] == (5, "2026-11-22T02:00:00Z")
    assert (cfg.state_dir / "ready-seen.tsv").read_text().count("\n") == 3


def test_the_queue_rows_carry_the_readys_time_and_the_listing_writes_the_ready_row(fx, tmp_path, monkeypatch):
    n = fx.ready("one", "feature/none-yet")
    row = fx.queue()[n]
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:00Z", row["readyAt"])
    ledger = tmp_path / "ledger.jsonl"
    monkeypatch.setenv("AUTOCODER_LANDING_TIMINGS", str(ledger))
    monkeypatch.delenv("AUTOCODER_LANDING_REPO", raising=False)
    sh(sys.executable, str(CLI), "--repo", str(fx.work), "--no-fetch", "queue")
    sh(sys.executable, str(CLI), "--repo", str(fx.work), "--no-fetch", "queue")
    rows = [json.loads(ln) for ln in ledger.read_text().splitlines()]
    assert [(r["kind"], r["issue"], r["event"], r["ts"], r["repo"]) for r in rows] == [("change", n, "ready", row["readyAt"], T.repo_id(fx.cfg()))]


# ── a READY says READY first, and its branch belongs to the issue (branchOwnership) ─────────
# On one project an FYI on a landed issue ("no label change here: the commits ride in the stack on `<the
# other issue's branch>` @ sha (READY posted on #<m> just now)") was read as that issue's newest READY: the
# close-out reopened the landed issue, the queue took it at the other issue's branch, and the plan held both
# out as conflicting. A READY comment says READY on its first line, and a branch it names must belong to
# the issue (its name carries the number, or a `stack:` line declares it) or the item is `foreign-branch`.
FYI = ("no label change here: slice 1a's three commits ride in the stack on `feature/issue-{m}-kickoff-deck` @ {sha} "
       "(READY posted on #{m} just now, this issue closes when that stack lands).")
MANAGER_NOTE = ("[swarm] manager: removing `ready-for-review`: `feature/issue-{m}-kickoff-deck` has a REAL merge conflict "
                "with master in `app/x.txt`; rebase, resolve, re-run the checks and re-READY.")
QUOTED = "For the record, #{m}'s READY was:\n> [swarm] READY: `feature/issue-{m}-kickoff-deck` @ {sha}, rebased on origin/master"
STACK_READY = ("[swarm] READY (stack): `feature/issue-{m}-kickoff-deck` @ {sha}, one tree for both slices.\n"
               "stack: `feature/issue-{m}-kickoff-deck` carries #{n} (slice 1a) and #{m}.")


def test_ready_lead_takes_the_real_ready_shapes_and_refuses_mentions(fx):
    cfg = fx.cfg()
    for body in ("READY `feature/issue-7` @ abc1234 (enqueued from a host that does not gate)",
                 "[swarm] READY: `feature/issue-7` @ 1fa7748735, rebased on origin/master d7443d1c",
                 "[Other swarm] READY — branch `fix/7-shell` @ 242781c299 on origin/master 78a62cb2d4",
                 "[swarm] **READY** (train). Branch `feat/7-zero` @ `5ba5835f0b`",
                 "[swarm] worker `w`: **READY** — `fix/7-stop` @ `e52f4aab8`",
                 "[swarm] worker `winfo`, worktree `wt-winfo`: claim and **READY, documents only**, branch `docs/7-pack` @ 2bd964db2a",
                 "**[swarm]** READY: #7 lands combined with #8 on `feat/8-admin` @ `cd156a55a`",
                 "[swarm] READY with #8: branch `fix/8-port` @ `ff8cc9e846`",
                 "✅ READY `feature/issue-7`",
                 "\n\n  [coordinator] READY again please"):
        assert T.ready_lead(cfg, body) is not None, body
    sha = "fee7171595"
    for body in (FYI.format(m=9, sha=sha), MANAGER_NOTE.format(m=9), QUOTED.format(m=9, sha=sha),
                 "FYI: #9's READY names `feature/issue-9-kickoff-deck`",
                 "Landed on master: `fix/9-port` (READY ff8cc9e846, w)",
                 "Progress. Branch `fix/7-sse` is at 0ac72b6f55 (prebank next, then READY).",
                 "Tracker: #8 and #9 are both READY",
                 "> [swarm] READY: `feature/issue-9-x` @ fee7171595",
                 "one two three four five six seven eight nine ten eleven twelve thirteen READY `feature/issue-7`",
                 "working on it\nREADY `feature/issue-7`"):   # not on the first line
        assert T.ready_lead(cfg, body) is None, body
    lead = T.ready_lead(cfg, "one two three four five six seven eight nine ten eleven twelve READY `feature/issue-7`")
    assert lead is not None and len(lead.split()) == 12   # the twelfth word is the limit


def test_is_ready_skips_the_trains_own_comments_and_mentions_ready_counts_the_word():
    cfg = T.Config(repo=Path("."), swarm="[swarm] train")
    assert T.is_ready(cfg, "READY `feature/issue-1`")
    assert T.is_ready(cfg, None) is False and T.is_ready(cfg, "") is False
    assert not T.is_ready(cfg, "[swarm] train: not trained, `tip-moved`: `feature/issue-1` @ abc; re-post READY at this tip")
    assert T.mentions_ready(cfg, [{"body": "working", "createdAt": None}, {"body": FYI.format(m=2, sha="abc1234"), "createdAt": None}])
    assert not T.mentions_ready(cfg, [{"body": "[swarm] train: re-post READY", "createdAt": None}, {"body": "ready-for-review", "createdAt": None}])


def test_branch_names_issue_and_stack_declares():
    for b in ("feature/issue-12", "enhancement/issue-12-auto", "fix/12-login", "12-login", "hotfix/x/issue-12-y", "feat/issue-12.1"):
        assert T.branch_names_issue(b, 12), b
    for b in ("feature/issue-120", "fix/112-login", "feature/x", "feature/issue-1", "fix/a12-b", "feature/issue12"):
        assert not T.branch_names_issue(b, 12), b
    assert T.stack_declares("READY `feature/issue-9-x` @ abc\nstack: `feature/issue-9-x` carries #8 (slice 1a) and #9", "feature/issue-9-x", 8)
    assert T.stack_declares("READY\n- **Stack**: `origin/feature/issue-9-x` carries #8", "feature/issue-9-x", 8)
    assert not T.stack_declares("READY `feature/issue-9-x`\nstack: `feature/issue-9-x` carries #80", "feature/issue-9-x", 8)   # #80 is not #8
    assert not T.stack_declares("READY `feature/issue-9-x`\nthe stack: `feature/issue-9-x` carries #8", "feature/issue-9-x", 8)  # not a `stack:` line
    assert not T.stack_declares("READY `feature/issue-9-x`\nstack: carries #8", "feature/issue-9-x", 8)                        # names no branch


def test_branch_ownership_is_issue_by_default_and_a_typo_refuses_to_load(tmp_path):
    fx = Fixture(tmp_path, {"branchOwnership": "issue"})
    assert fx.cfg().branch_ownership == "issue"
    fx.root.joinpath("d.json").write_text(json.dumps({"train": {}}))
    assert T.load_config(fx.work, fx.root / "d.json").branch_ownership == "issue"   # the default
    fx.root.joinpath("t.json").write_text(json.dumps({"train": {"branchOwnership": "mine"}}))
    with pytest.raises(SystemExit, match=r"train\.branchOwnership in .*t\.json .*'mine'"):
        T.load_config(fx.work, fx.root / "t.json")


def owned_ready(fx, title, suffix="x", body=None):
    """An issue whose branch carries its number, READY posted; returns (issue, branch)."""
    n = fx.issue(title)
    b = f"feature/issue-{n}-{suffix}"
    fx.branch(b, {f"{b.replace('/', '-')}.txt": "1\n"})
    fx.comment(n, (body or "[swarm] READY: `{b}` @ {sha}").format(b=b, sha=T.short_tip(fx.cfg(), b), n=n))
    return n, b


def test_queue_plans_an_owned_branch_and_reports_a_foreign_one_without_planning_it(tmp_path):
    fx = Fixture(tmp_path, {"branchOwnership": "issue"})
    own, own_b = owned_ready(fx, "own")
    other, other_b = owned_ready(fx, "other")
    foreign = fx.issue("foreign")
    fx.comment(foreign, f"[swarm] READY: `{other_b}` @ {T.short_tip(fx.cfg(), other_b)} (the work is on the other branch)")
    q = fx.queue()
    assert q[own]["state"] == "queue" and q[own]["branch"] == own_b
    assert q[foreign]["state"] == "foreign-branch" and q[foreign]["branch"] == other_b and q[foreign]["tip"] == T.short_tip(fx.cfg(), other_b)
    assert f"`{other_b}` does not belong to #{foreign}" in q[foreign]["note"] and f"stack: `{other_b}` carries #{foreign}" in q[foreign]["note"]
    out, fault = fx.plan()
    assert fault is None and [ln.split("\t")[1] for ln in out if ln.startswith("train\t")] == sorted([str(own), str(other)], key=int)
    assert any(ln.startswith(f"skip\t{foreign}\t{other_b}\tforeign-branch") for ln in out)   # reported, never a member
    # the newest READY is the worker's word: a foreign branch in it is not papered over by an older READY naming an owned one
    fx.comment(own, f"[swarm] READY: `{other_b}` @ {T.short_tip(fx.cfg(), other_b)}")
    assert fx.queue()[own]["state"] == "foreign-branch"


def test_queue_takes_a_declared_stack_and_the_fyi_shape_is_no_ready(tmp_path):
    fx = Fixture(tmp_path, {"branchOwnership": "issue"})
    upper, upper_b = owned_ready(fx, "upper", "kickoff-deck")
    sha = T.short_tip(fx.cfg(), upper_b)
    lower = fx.issue("lower")
    fx.comment(lower, FYI.format(m=upper, sha=sha).replace(f"issue-{upper}-kickoff-deck", upper_b.split("/", 1)[1]))
    q = fx.queue()
    assert q[lower]["state"] == "no-ready" and q[lower]["branch"] == "-" and "says READY on its first line" in q[lower]["note"]
    assert q[upper]["state"] == "queue"
    fx.comment(lower, f"[swarm] READY (stack): `{upper_b}` @ {sha}\nstack: `{upper_b}` carries #{lower} (slice 1a) and #{upper}.")
    q = fx.queue()
    assert q[lower]["state"] == "queue" and q[lower]["branch"] == upper_b and q[lower]["named"] == sha
    out, _ = fx.plan()
    assert sum(1 for ln in out if ln.startswith("train\t")) == 2   # the stack's tip is a member once; the lower slice rides on it


def test_a_genuine_ready_is_not_shadowed_by_a_later_fyi(tmp_path):
    fx = Fixture(tmp_path, {"branchOwnership": "issue"})
    n, b = owned_ready(fx, "n")
    other, other_b = owned_ready(fx, "other")
    fx.comment(n, FYI.format(m=other, sha=T.short_tip(fx.cfg(), other_b)).replace(f"issue-{other}-kickoff-deck", other_b.split("/", 1)[1]))
    assert fx.queue()[n]["state"] == "queue" and fx.queue()[n]["branch"] == b


def landed_and_closed(fx, title="lower"):
    """An owned branch landed on master and its issue closed: (issue, branch, landed sha)."""
    n, b = owned_ready(fx, title)
    fx.land(b)
    sh(sys.executable, str(ISSUES_FILE), "close", str(n), cwd=fx.work)
    return n, b, T.git(fx.work, "rev-parse", "origin/master").stdout.strip()


@pytest.mark.parametrize("shape", ["fyi", "manager-note", "quoted-ready"])
def test_a_landed_issue_stays_closed_for_an_fyi_a_managers_note_or_a_quoted_ready(tmp_path, shape):
    """The acceptance fixture: the FYI quoting another issue's READY and branch leaves the landed issue closed."""
    fx = Fixture(tmp_path, {"branchOwnership": "issue"})
    n, b, landed = landed_and_closed(fx)
    m, m_b = owned_ready(fx, "upper", "kickoff-deck")   # the other issue's branch, not carried by the landing
    sha = T.short_tip(fx.cfg(), m_b)
    body = {"fyi": FYI, "manager-note": MANAGER_NOTE, "quoted-ready": QUOTED}[shape].format(m=m, sha=sha)
    fx.comment(n, body.replace(f"issue-{m}-kickoff-deck", m_b.split("/", 1)[1]))
    cfg = fx.cfg()
    assert T.newer_ready(cfg, n, b, landed) is None
    assert T.reopen_if_newer_ready(cfg, n, b, landed) is False
    assert json.loads(T.tracker(cfg, "issue_get", str(n)).stdout)["state"] == "CLOSED"


def test_a_landed_issue_stays_closed_for_a_ready_on_a_foreign_branch_and_reopens_for_a_declared_stack(tmp_path):
    fx = Fixture(tmp_path, {"branchOwnership": "issue"})
    n, b, landed = landed_and_closed(fx)
    m, m_b = owned_ready(fx, "upper", "kickoff-deck")
    sha = T.short_tip(fx.cfg(), m_b)
    cfg = fx.cfg()
    fx.comment(n, f"[swarm] READY: `{m_b}` @ {sha}")   # a READY, but the branch is another issue's and no stack line says otherwise
    assert T.newer_ready(cfg, n, b, landed) is None and T.reopen_if_newer_ready(cfg, n, b, landed) is False
    assert fx.queue().get(n) is None   # closed: not listed
    fx.comment(n, STACK_READY.format(m=m, sha=sha, n=n).replace(f"issue-{m}-kickoff-deck", m_b.split("/", 1)[1]))
    assert T.reopen_if_newer_ready(cfg, n, b, landed) is True
    issue = json.loads(T.tracker(cfg, "issue_get", str(n)).stdout)
    assert issue["state"] == "OPEN" and m_b in issue["body"]
    # the reopened issue rejoins the queue through `list` on the file backend too (#325)
    assert fx.queue()[n]["state"] == "queue" and fx.queue()[n]["branch"] == m_b
