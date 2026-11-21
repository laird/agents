"""merge queue and train planner (train_lib.py, merge-train.py): READY pickup, overrides, classification,
ordering, the planner (next candidate on conflict, prefilter first, stacks at their tip, a failed merge
cleared) and the mechanical reopen, over a real git fixture repo and the file issue backend."""

from __future__ import annotations

import json
import os
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
        cfg = {"issueSource": "file", "issueDir": str(self.issues), "train": config or {}}
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


def test_ready_comments_keeps_tracker_timestamps_and_none_when_absent():
    issue = {"comments": [{"body": "x", "createdAt": "2026-01-01T00:00:00Z"}, {"body": "y"}]}
    assert [c["createdAt"] for c in T.ready_comments(issue)] == ["2026-01-01T00:00:00Z", None]


def test_pick_ready_prefers_the_newest_ready_naming_an_existing_branch(fx):
    fx.branch("feature/real", {"a.txt": "1\n"})
    cfg = fx.cfg()
    cs = [{"body": "READY `feature/real`", "createdAt": None},
          {"body": "rebase and re-READY, no branch named", "createdAt": None},
          {"body": "READY `feature/gone`", "createdAt": None}]
    assert T.pick_ready(cfg, cs)["branch"] == "feature/real"


def test_pick_ready_reports_the_tried_names_when_none_exists(fx):
    p = T.pick_ready(fx.cfg(), [{"body": "READY `feature/gone`", "createdAt": None}])
    assert p["branch"] is None and p["candidates"] == ["feature/gone"]


def test_pick_ready_note_pattern_skips_coordinator_notes_for_the_fallback(fx):
    fx.root.joinpath("c.json").write_text(json.dumps({"train": {"notePattern": r"^\[coordinator\]"}}))
    cfg = T.load_config(fx.work, fx.root / "c.json")
    cs = [{"body": "READY from the worker", "createdAt": None}, {"body": "[coordinator] READY again please", "createdAt": None}]
    assert T.pick_ready(cfg, cs)["body"] == "READY from the worker"


def test_pick_ready_is_none_without_a_ready_comment(fx):
    assert T.pick_ready(fx.cfg(), [{"body": "working on it", "createdAt": None}]) is None


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
    fx.root.joinpath("c.json").write_text(json.dumps({"train": {"readyLabels": ["ready-for-review", "host:x"]}}))
    cfg = T.load_config(fx.work, fx.root / "c.json")
    assert T.plan_queue(cfg) == []
    quiet = fx.issue("labelled but never said READY")
    assert quiet not in {r["issue"] for r in T.plan_queue(fx.cfg())}


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
    fx.root.joinpath("c.json").write_text(json.dumps({"train": {"classifyLimit": 1}}))
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
    fx.root.joinpath("c.json").write_text(json.dumps({"train": {"hooks": {"mergeFault": "printf 'generator-failed\\tgen died on %s\\n' \"$(head -1)\""}}}))
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
    fx.root.joinpath("c.json").write_text(json.dumps({"train": {"hooks": {"mergeFault": "printf 'driver-fault\\tno toolchain\\n'"}}}))
    fx.branch("feature/a", {"data.bin": "A\n"})
    fx.branch("feature/b", {"data.bin": "B\n"})
    fx.ready("a", "feature/a"); b = fx.ready("b", "feature/b")
    cfg = T.load_config(fx.work, fx.root / "c.json")
    rows, fault = T.plan_train(cfg, T.plan_queue(cfg))
    assert f"#{b}" in fault and "no toolchain" in fault
    assert not any(r.startswith(("skip", "drop")) and f"\t{b}\t" in r for r in rows)


def test_prepare_scratch_hook_failure_stops_the_plan_with_a_named_fault(fx):
    fx.root.joinpath("c.json").write_text(json.dumps({"train": {"hooks": {"prepareScratch": "echo toolchain broken >&2; exit 4"}}}))
    fx.branch("feature/a", {"a.txt": "1\n"})
    fx.ready("a", "feature/a")
    cfg = T.load_config(fx.work, fx.root / "c.json")
    rows, fault = T.plan_train(cfg, T.plan_queue(cfg))
    assert rows == [] and "prepareScratch exited 4" in fault and "toolchain broken" in fault


def test_seed_dirs_are_hardlink_copies_and_reseeded_when_the_marker_changes(fx):
    fx.root.joinpath("c.json").write_text(json.dumps({"train": {"seedDirs": ["deps"], "seedMarker": "stamp"}}))
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
