"""The queue's dependency-bot pass (train_depbot.py, `merge-train.py depbot`, the daemon's tick and the landing
close-out), over a real git fixture repo, the file issue backend and a FAKE `gh` whose PR store is a JSON file.

The READY the pass posts is pinned against the planner's OWN parser (train_lib.pick_ready, plan_queue under
`branchOwnership: issue`), never against its text, so the two cannot drift: a bot branch carries no issue number,
and the one form the planner accepts for it is the `stack:` line.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parent.parent / "plugins" / "autocoder" / "scripts"
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import train_lib as T  # noqa: E402
import train_depbot as D  # noqa: E402
import train_run as R  # noqa: E402
from test_merge_train import Fixture, sh  # noqa: E402
from test_merge_train_run import Fx  # noqa: E402

CLI = SCRIPTS / "merge-train.py"
ISSUES_FILE = SCRIPTS / "issues-file.py"

# A `gh` for the three PR forms the pass uses, over FAKE_PR_STORE ({"prs": [...], "log": [...], "fail": "..."}).
FAKE_GH = r'''#!/usr/bin/env python3
import json, os, sys
store = os.environ["FAKE_PR_STORE"]
data = json.load(open(store))
args = sys.argv[1:]
data.setdefault("log", []).append(args)
def save(): json.dump(data, open(store, "w"), indent=1)
if args[:2] == ["pr", "list"]:
    if data.get("fail") == "list":
        save(); print("HTTP 401: Bad credentials", file=sys.stderr); sys.exit(1)
    print(json.dumps([p for p in data["prs"] if p.get("state", "OPEN") == "OPEN"])); save(); sys.exit(0)
if args[:2] == ["pr", "view"]:
    hit = [p for p in data["prs"] if str(p["number"]) == args[2]]
    if not hit: save(); print("no pull requests found", file=sys.stderr); sys.exit(1)
    print(json.dumps(hit[0])); save(); sys.exit(0)
if args[:2] == ["pr", "close"]:
    for p in data["prs"]:
        if str(p["number"]) == args[2]:
            p["state"] = "CLOSED"; p["closeComment"] = args[args.index("--comment") + 1] if "--comment" in args else ""
            save(); sys.exit(0)
    save(); print("no such PR", file=sys.stderr); sys.exit(1)
save(); print("fake gh: unsupported " + " ".join(args), file=sys.stderr); sys.exit(1)
'''


class Store:
    """The fake gh's PR store: bot PRs are added as branches are pushed."""

    def __init__(self, root: Path):
        self.path = root / "prs.json"
        self.gh = root / "fake-gh.py"
        self.gh.write_text(FAKE_GH)
        self.path.write_text(json.dumps({"prs": [], "log": []}))
        os.environ["FAKE_PR_STORE"] = str(self.path)
        os.environ["AUTOCODER_DEPBOT_GH"] = f"{sys.executable} {self.gh}"

    def read(self):
        return json.loads(self.path.read_text())

    def write(self, data):
        self.path.write_text(json.dumps(data, indent=1))

    def add(self, number, head, tip, author="app/dependabot", title=None, created=None, body="Bumps lodash from 4.17.20 to 4.17.21.\n<!-- a bot marker -->"):
        data = self.read()
        data["prs"].append({"number": number, "headRefName": head, "headRefOid": tip, "createdAt": created or "2026-01-01T00:00:00Z",
                            "title": title or f"Bump a dependency on {head}", "body": body, "url": f"https://example.invalid/pull/{number}",
                            "author": {"login": author, "is_bot": True}, "state": "OPEN"})
        self.write(data)

    def set(self, number, **fields):
        data = self.read()
        for p in data["prs"]:
            if p["number"] == number:
                p.update(fields)
        self.write(data)

    def pr(self, number):
        return next(p for p in self.read()["prs"] if p["number"] == number)

    def fail(self, what):
        data = self.read()
        data["fail"] = what
        self.write(data)


DEPBOT = {"branchOwnership": "issue", "depbot": {"authors": ["dependabot[bot]"], "labels": ["ready-for-review", "host:a"], "everySeconds": 600}}


@pytest.fixture
def fx(tmp_path):
    store = Store(tmp_path)
    f = Fixture(tmp_path, DEPBOT)
    f.store = store
    return f


def tip_of(fx, branch):
    return T.git(fx.work, "rev-parse", f"origin/{branch}").stdout.strip()


def bot_pr(fx, number, head="dependabot/npm_and_yarn/lodash-4.17.21", files=None):
    fx.branch(head, files or {"package-lock.json": f"lodash {number}\n"})
    fx.store.add(number, head, tip_of(fx, head))
    return head


def run_pass(fx, now=None):
    cfg = fx.cfg()
    ps = D.Pass(cfg, D.settings(cfg), log=lambda m: None, now=now).run()
    ps.save()
    return ps


def issue_doc(fx, n):
    return json.loads(sh(sys.executable, str(ISSUES_FILE), "get", str(n), cwd=fx.work).stdout)


def readys(fx, n):
    cfg = fx.cfg()
    return [c["body"] for c in T.ready_comments(issue_doc(fx, n)) if T.is_ready(cfg, c["body"])]


# ── configuration ───────────────────────────────────────────────────────────────────────
def test_the_pass_is_off_without_a_depbot_object_and_on_with_defaults(tmp_path):
    f = Fixture(tmp_path)
    assert D.settings(f.cfg()).enabled is False
    for sub in ("b", "c", "d"):
        (tmp_path / sub).mkdir()
    f = Fixture(tmp_path / "b", {"depbot": {}, "anyLabels": ["host:x", "host:y"]})
    st = D.settings(f.cfg())
    assert st.enabled and st.authors == ["dependabot[bot]"] and st.priority == "first" and st.every == 900 and st.limit == 100
    assert st.labels == ["ready-for-review", "host:x"]   # the queue's READY label plus the first scope label
    assert st.title_prefix == "Dependency update PR"
    f = Fixture(tmp_path / "c", {"depbot": {"enabled": False}})
    assert D.settings(f.cfg()).enabled is False
    f = Fixture(tmp_path / "d", {"depbot": {"authors": "dependabot"}})
    with pytest.raises(SystemExit):
        D.settings(f.cfg())


def test_a_configured_label_list_always_carries_the_ready_labels(tmp_path):
    f = Fixture(tmp_path, {"depbot": {"labels": ["host:b"]}})
    assert D.settings(f.cfg()).labels == ["host:b", "ready-for-review"]


def test_package_key_folds_the_number_hash_and_version_away():
    assert D.package_key("dependabot/npm_and_yarn/lodash-4.17.21") == "npm_and_yarn/./lodash"
    assert D.package_key("dependabot/npm_and_yarn/app/web/minor-deps-0123456789") == "npm_and_yarn/app/web/minor-deps"
    assert D.package_key("dependabot/github_actions/actions/checkout-5") == "github_actions/actions/checkout"
    assert D.package_key("dependabot/pip") == "pip/./pip"
    assert D.package_key("renovate/lodash-4.x") == "renovate/lodash"
    assert D._login("app/dependabot") == D._login("dependabot[bot]") == D._login("Dependabot") == "dependabot"


# ── a bot PR gets a tracking issue and a READY the planner accepts ───────────────────────
def test_a_bot_pr_with_no_tracking_issue_gets_one_whose_ready_the_planner_plans_first(fx):
    older = fx.ready("an older P0", "feature/issue-1-x", labels=("ready-for-review", "P0"))   # a hand READY ahead by priority and age
    fx.branch("feature/issue-1-x", {"a.txt": "1\n"})
    head = bot_pr(fx, 7)
    ps = run_pass(fx)
    assert [r["action"] for r in ps.rows] == ["filed"] and ps.error == ""
    n = ps.rows[0]["issue"]
    doc = issue_doc(fx, n)
    assert doc["state"] == "OPEN" and {"ready-for-review", "host:a"} <= {lb["name"] for lb in doc["labels"]}
    assert f"<!-- depbot-pr 7 -->" in doc["body"] and "<!-- depbot-key npm_and_yarn/./lodash -->" in doc["body"]
    assert "https://example.invalid/pull/7" in doc["body"] and "Bumps lodash" in doc["body"] and "<!-- a bot marker -->" not in doc["body"]
    assert doc["title"].startswith("Dependency update PR #7: ")
    # the READY, read by the planner's own parser: READY first, the bot branch resolved AS THE ISSUE'S, the tip named
    cfg = fx.cfg()
    picked = T.pick_ready(cfg, T.ready_comments(doc), n)
    assert picked["branch"] == head and picked["foreign"] is None and picked["named"] == tip_of(fx, head)[:10]
    assert T.stack_declares(picked["body"], head, n) and "flag: none" in picked["body"]
    rows = T.plan_queue(cfg)
    by = {r["issue"]: r for r in rows}
    assert by[n]["state"] == "queue" and by[n]["branch"] == head and by[n]["tip"] == tip_of(fx, head)[:10]
    assert rows[0]["issue"] == n and by[older]["order"] > by[n]["order"]   # first in priority, ahead of the P0
    assert f"first {n} # depbot PR #7" in cfg.overrides.read_text()
    assert D.status_segment(ps.record(), now=datetime(2026, 1, 1, 0, 30, tzinfo=timezone.utc)) == f"depbot: 1 open, oldest 3 passes (#7->#{n} filed)"


def test_a_second_pass_files_nothing_twice_and_posts_no_second_ready(fx):
    bot_pr(fx, 7)
    first = run_pass(fx)
    n = first.rows[0]["issue"]
    second = run_pass(fx)
    assert [(r["issue"], r["action"]) for r in second.rows] == [(n, "tracked")]
    assert len(readys(fx, n)) == 1
    listing = json.loads(sh(sys.executable, str(ISSUES_FILE), "list", "--state", "all", cwd=fx.work).stdout)
    assert [i["number"] for i in listing] == [n]
    assert fx.cfg().overrides.read_text().count("# depbot") == 1


def test_a_moved_tip_gets_a_new_ready_and_the_queue_plans_the_new_tip(fx):
    head = bot_pr(fx, 7)
    n = run_pass(fx).rows[0]["issue"]
    old = tip_of(fx, head)
    fx.commit_on(head, {"package-lock.json": "lodash 7 again\n"}, "the bot recreated the branch")   # new work, not a rebase: `tip-moved` to the queue
    fx.store.set(7, headRefOid=tip_of(fx, head))
    assert fx.queue()[n]["state"] == "tip-moved"
    ps = run_pass(fx)
    assert ps.rows[0]["action"] == "ready" and old[:10] in ps.rows[0]["note"]
    rs = readys(fx, n)
    assert len(rs) == 2 and T.named_tip(rs[-1], head) == tip_of(fx, head)[:10]
    row = fx.queue()[n]
    assert row["state"] == "queue" and row["tip"] == tip_of(fx, head)[:10]
    assert run_pass(fx).rows[0]["action"] == "tracked"   # and the next pass is quiet


def test_a_hand_removed_marker_issue_is_found_by_its_title(fx):
    head = bot_pr(fx, 7)
    n = fx.issue("Dependency update PR #7: hand made", labels=("ready-for-review",), body="made by hand, no marker")
    ps = run_pass(fx)
    assert [(r["issue"], r["action"]) for r in ps.rows] == [(n, "ready")]
    assert T.pick_ready(fx.cfg(), T.ready_comments(issue_doc(fx, n)), n)["branch"] == head


def test_a_hand_ready_naming_the_bot_branch_without_a_sha_is_left_alone(fx):
    head = bot_pr(fx, 7)
    n = fx.issue("Dependency update PR #7: hand made", labels=("ready-for-review",), body="made by hand")
    fx.comment(n, f"READY `{head}`\nstack: `{head}` carries #{n}")
    assert [r["action"] for r in run_pass(fx).rows] == ["tracked"] and len(readys(fx, n)) == 1


def test_a_workers_ready_on_the_tracking_issue_stands(fx):
    head = bot_pr(fx, 7)
    n = run_pass(fx).rows[0]["issue"]
    fx.branch(f"fix/{n}-pin-the-one-package", {"package-lock.json": "lodash 7 pinned\n"})
    fx.comment(n, f"READY `fix/{n}-pin-the-one-package` @ {tip_of(fx, f'fix/{n}-pin-the-one-package')[:10]}: the bot tip was red, this pins it")
    fx.commit_on(head, {"package-lock.json": "bot moved\n"})
    fx.store.set(7, headRefOid=tip_of(fx, head))
    ps = run_pass(fx)
    assert ps.rows[0]["action"] == "worker-branch" and len(readys(fx, n)) == 2
    assert fx.queue()[n]["branch"] == f"fix/{n}-pin-the-one-package"


# ── a replaced PR supersedes its older tracking issue; a gone PR closes it ───────────────
def test_a_recreated_pr_supersedes_the_older_tracking_issue_of_the_same_key(fx):
    bot_pr(fx, 7, head="dependabot/npm_and_yarn/lodash-4.17.21")
    old = run_pass(fx).rows[0]["issue"]
    fx.store.set(7, state="CLOSED")   # the bot closed PR 7 and opened PR 9 for the newer version
    bot_pr(fx, 9, head="dependabot/npm_and_yarn/lodash-4.17.22")
    ps = run_pass(fx)
    assert [(r["pr"], r["action"]) for r in ps.rows] == [(9, "filed")]
    new = ps.rows[0]["issue"]
    assert new != old and issue_doc(fx, old)["state"] == "CLOSED" and issue_doc(fx, new)["state"] == "OPEN"
    told = "\n".join(c["body"] for c in T.ready_comments(issue_doc(fx, old)))
    assert "superseded" in told and "PR #9" in told and "npm_and_yarn/./lodash" in told
    assert ps.closed == [{"issue": old, "pr": 7, "why": ps.closed[0]["why"]}]
    ov = fx.cfg().overrides.read_text()
    assert f"first {new} # depbot" in ov and f"first {old} " not in ov
    rows = fx.queue()
    assert rows[new]["state"] == "queue" and old not in rows


def test_an_open_tracking_issue_whose_pr_was_merged_or_closed_elsewhere_is_closed_with_the_reason(fx):
    bot_pr(fx, 7)
    bot_pr(fx, 8, head="dependabot/pip/requests-2.32.4")
    issues = {r["pr"]: r["issue"] for r in run_pass(fx).rows}
    fx.store.set(7, state="MERGED", mergeCommit={"oid": "abcdef1234567890"})
    fx.store.set(8, state="CLOSED")
    ps = run_pass(fx)
    assert ps.rows == [] and {c["issue"] for c in ps.closed} == set(issues.values())
    assert issue_doc(fx, issues[7])["state"] == "CLOSED" and "merged" in ps.closed[0]["why"] + ps.closed[1]["why"]
    assert "abcdef1234" in "\n".join(c["body"] for c in T.ready_comments(issue_doc(fx, issues[7])))
    assert "closed without landing" in "\n".join(c["body"] for c in T.ready_comments(issue_doc(fx, issues[8])))
    assert "# depbot" not in fx.cfg().overrides.read_text()
    assert D.status_segment(ps.record()) == "depbot: 0 open"


def test_a_closed_tracking_issue_for_a_pr_still_open_files_nothing_new(fx):
    bot_pr(fx, 7)
    n = run_pass(fx).rows[0]["issue"]
    sh(sys.executable, str(ISSUES_FILE), "close", str(n), "--comment", "landed another way", cwd=fx.work)
    ps = run_pass(fx)
    assert [(r["issue"], r["action"]) for r in ps.rows] == [(n, "closed-tracking")]
    listing = json.loads(sh(sys.executable, str(ISSUES_FILE), "list", "--state", "all", cwd=fx.work).stdout)
    assert [i["number"] for i in listing] == [n]


def test_hand_override_rows_survive_the_sync(fx):
    cfg = fx.cfg()
    cfg.overrides.parent.mkdir(parents=True, exist_ok=True)
    cfg.overrides.write_text("# mine\nhold 3 waiting on the owner\nfirst 4\n")
    bot_pr(fx, 7)
    n = run_pass(fx).rows[0]["issue"]
    assert cfg.overrides.read_text() == f"# mine\nhold 3 waiting on the owner\nfirst 4\nfirst {n} # depbot PR #7\n"
    assert D.sync_first_rows(cfg.overrides, {n: 7}) is False   # unchanged: not rewritten


def test_a_priority_label_instead_of_a_first_row(tmp_path):
    store = Store(tmp_path)
    f = Fixture(tmp_path, {"branchOwnership": "issue", "depbot": {"priority": "P0"}})
    f.store = store
    bot_pr(f, 7)
    n = run_pass(f).rows[0]["issue"]
    assert "P0" in {lb["name"] for lb in issue_doc(f, n)["labels"]} and not f.cfg().overrides.is_file()


# ── a failed PR listing is said, never a zero ───────────────────────────────────────────
def test_a_pr_list_failure_reads_unknown_in_the_status_line_and_decides_nothing(fx):
    bot_pr(fx, 7)
    fx.store.fail("list")
    ps = run_pass(fx)
    assert ps.error.startswith("pr list failed") and ps.rows == [] and ps.closed == []
    assert D.status_segment(ps.record()) == "depbot: unknown (pr list failed)"
    listing = json.loads(sh(sys.executable, str(ISSUES_FILE), "list", "--state", "all", cwd=fx.work).stdout)
    assert listing == []   # nothing filed on a blind pass
    r = subprocess.run([sys.executable, str(CLI), "--repo", str(fx.work), "depbot"], capture_output=True, text=True, cwd=fx.work)
    assert r.returncode == 1 and r.stdout.strip().splitlines()[-1] == "depbot: unknown (pr list failed)"
    r = subprocess.run([sys.executable, str(CLI), "--repo", str(fx.work), "--no-fetch", "queue", "--status-line"], capture_output=True, text=True, cwd=fx.work)
    assert r.returncode == 0 and r.stdout.splitlines()[0].endswith(" | depbot: unknown (pr list failed)")


def test_the_cli_runs_the_pass_and_prints_a_row_per_pr_and_the_segment_last(fx):
    head = bot_pr(fx, 7)
    r = subprocess.run([sys.executable, str(CLI), "--repo", str(fx.work), "depbot"], capture_output=True, text=True, cwd=fx.work)
    assert r.returncode == 0, r.stderr
    lines = r.stdout.strip().splitlines()
    cols = lines[0].split("\t")
    assert cols[0] == "7" and cols[1] == head and cols[2] == tip_of(fx, head)[:10] and cols[4] == "filed"
    assert lines[-1].startswith("depbot: 1 open, oldest ") and lines[-1].endswith(f"(#7->#{cols[3]} filed)")
    r = subprocess.run([sys.executable, str(CLI), "--repo", str(fx.work), "--no-fetch", "queue", "--status-line"], capture_output=True, text=True, cwd=fx.work)
    assert f"| next #{cols[3]} {head} @" in r.stdout.splitlines()[0] and "| depbot: 1 open" in r.stdout.splitlines()[0]
    (fx.work / ".autocoder.json").write_text(json.dumps({"issueSource": "file", "issueDir": str(fx.issues), "train": {"branchOwnership": "issue"}}))
    r = subprocess.run([sys.executable, str(CLI), "--repo", str(fx.work), "--no-fetch", "depbot"], capture_output=True, text=True, cwd=fx.work)
    assert r.returncode == 4 and "is off" in r.stderr


def test_the_status_segment_without_a_record_and_the_pass_unit():
    assert D.status_segment(None) == "depbot: not run yet"
    rec = {"every": 900, "open": [{"pr": 1, "issue": 2, "action": "tracked", "createdAt": "2026-01-01T00:00:00Z"}]}
    assert D.status_segment(rec, now=datetime(2026, 1, 2, tzinfo=timezone.utc)) == "depbot: 1 open, oldest 96 passes (#1->#2 tracked)"
    assert D.status_segment({"error": "issue list failed: x", "open": []}) == "depbot: unknown (issue list failed)"


# ── the landing close-out closes the PR; the daemon runs the pass ───────────────────────
def test_a_landed_tracking_issue_closes_the_pr_naming_the_sha_and_the_bot_branch_is_deleted(tmp_path):
    store = Store(tmp_path)
    f = Fx(tmp_path, {"branchOwnership": "issue", "depbot": {"everySeconds": 0}})
    head = "dependabot/npm_and_yarn/lodash-4.17.21"
    sh("git", "checkout", "-q", "-B", head, "origin/master", cwd=f.work)
    (f.work / "files").mkdir(exist_ok=True)
    (f.work / "files/lock.txt").write_text("lodash 4.17.21\n")
    sh("git", "add", "-A", cwd=f.work)
    sh("git", "commit", "-q", "-m", "bump lodash", cwd=f.work)
    sh("git", "push", "-q", "-f", "origin", head, cwd=f.work)
    sh("git", "checkout", "-q", "master", cwd=f.work)
    sh("git", "fetch", "-q", "origin", cwd=f.work)
    tip = T.git(f.work, "rev-parse", f"origin/{head}").stdout.strip()
    store.add(7, head, tip)
    cfg = f.rc().cfg
    ps = D.Pass(cfg, D.settings(cfg), log=lambda m: None).run()
    n = ps.rows[0]["issue"]
    code, _ = f.run()   # the cycle plans the tracking issue through its READY alone and lands it
    assert code == 0 and f.state_of(n) == "CLOSED"
    sh("git", "fetch", "-q", "--prune", "origin", cwd=f.work)
    landed = T.git(f.work, "rev-parse", "origin/master").stdout.strip()
    assert sh("git", "cat-file", "-e", "origin/master:files/lock.txt", cwd=f.work, check=False).returncode == 0
    pr = store.pr(7)
    assert pr["state"] == "CLOSED" and landed[:10] in pr["closeComment"] and f"#{n}" in pr["closeComment"] and "merge-train:" in pr["closeComment"]
    assert sh("git", "rev-parse", "--verify", "-q", f"origin/{head}", cwd=f.work, check=False).returncode != 0   # the bot branch is gone
    assert any(a[:2] == ["pr", "close"] for a in store.read()["log"])
    # an ordinary member (no marker) closes no PR
    log_before = len(store.read()["log"])
    other = f.member(1)
    sh(sys.executable, str(ISSUES_FILE), "comment", str(other), "--body", f"READY `feature/m1`\nstack: `feature/m1` carries #{other}", cwd=f.work)
    f.run()
    assert f.state_of(other) == "CLOSED" and not any(a[:2] == ["pr", "close"] for a in store.read()["log"][log_before:])


def test_the_daemon_runs_the_pass_at_most_once_per_interval_and_logs_the_segment(tmp_path):
    store = Store(tmp_path)
    f = Fx(tmp_path, {"branchOwnership": "issue", "depbot": {"everySeconds": 3600}})
    head = "dependabot/pip/requests-2.32.4"
    sh("git", "checkout", "-q", "-B", head, "origin/master", cwd=f.work)
    (f.work / "req.txt").write_text("requests==2.32.4\n")
    sh("git", "add", "-A", cwd=f.work)
    sh("git", "commit", "-q", "-m", "bump requests", cwd=f.work)
    sh("git", "push", "-q", "-f", "origin", head, cwd=f.work)
    sh("git", "checkout", "-q", "master", cwd=f.work)
    store.add(7, head, T.git(f.work, "rev-parse", head).stdout.strip())   # NOT fetched into the clone yet: the daemon's pass fetches first
    logged = []
    d = R.Daemon(f.rc(), log=logged.append, interval=1, max_ticks=1, sleep=lambda s: None, cycle=lambda: type("C", (), {"run": lambda self, **kw: (0, None)})())
    assert d.loop() == 0
    rec = json.loads((f.rc().cfg.state_dir / "depbot.json").read_text())
    assert rec["error"] == "" and [r["action"] for r in rec["open"]] == ["filed"]
    assert any("dependency-bot pass in" in m and "depbot: 1 open, oldest" in m for m in logged)
    n = rec["open"][0]["issue"]
    assert T.pick_ready(f.rc().cfg, T.ready_comments(json.loads(T.tracker(f.rc().cfg, "issue_get", str(n)).stdout)), n)["branch"] == head
    lists = lambda: sum(1 for a in store.read()["log"] if a[:2] == ["pr", "list"])
    before = lists()
    d = R.Daemon(f.rc(), log=logged.append, interval=1, max_ticks=2, sleep=lambda s: None, cycle=lambda: type("C", (), {"run": lambda self, **kw: (0, None)})())
    assert d.loop() == 0 and lists() == before   # inside the interval: no second pass
    store.fail("list")
    f.train["depbot"]["everySeconds"] = 0
    f.write_config()
    d = R.Daemon(f.rc(), log=logged.append, interval=1, max_ticks=1, sleep=lambda s: None, cycle=lambda: type("C", (), {"run": lambda self, **kw: (0, None)})())
    assert d.loop() == 0 and lists() == before + 1
    assert any("depbot: unknown (pr list failed)" in m for m in logged)
    assert json.loads((f.rc().cfg.state_dir / "daemon.json").read_text())["verdict"] in ("idle", "cycle:0")   # the tick went on


def test_a_transport_error_on_the_pr_listing_is_retried(fx, monkeypatch):
    bot_pr(fx, 7)
    calls = []
    cfg = fx.cfg()
    st = D.settings(cfg)
    pulls = D.Pulls(cfg, st, sleep=lambda s: calls.append(s))
    real = subprocess.run

    def flaky(cmd, **kw):
        if cmd[-1] == D.PR_FIELDS and not calls:
            return subprocess.CompletedProcess(cmd, 1, "", "dial tcp: i/o timeout")
        return real(cmd, **kw)
    monkeypatch.setattr(D.subprocess, "run", flaky)
    assert [p["number"] for p in pulls.list_open()] == [7] and calls == [T.TRACKER_RETRY_PAUSES[0]]
