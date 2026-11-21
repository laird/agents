"""merge train run (train_run.py, merge-train-run.py): assembly, the gate, publish and close-out, and the
red-batch rules, over a real git fixture repo, the file issue backend and a SCRIPTED gate.

The scripted gate (`gate.sh`, written per fixture) stands in for merge-to-integration.sh and keeps its
contract: exit 0 plus a `merged into` line mean the tree landed (here: a fast-forward push to master);
anything else is red, with an `::error::` line. A member is bad when it adds a file under `bad/`; the red
line names no path unless the fixture asks it to. `infra.script` lists outcomes consumed one per gate
(`infra` = an INFRASTRUCTURE refusal). `gates.log` records, per gate, the files the tree adds to master.
With `squash` present the gate lands the way merge-to-integration.sh lands a branch that holds merge
commits (every train does): ONE squash commit on master, no member tip in its history; `squash-omit`
lists paths left out of that commit (a landing that did not carry a member's work).
"""

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
import train_run as R  # noqa: E402

ISSUES_FILE = SCRIPTS / "issues-file.py"
CLI = SCRIPTS / "merge-train-run.py"

GATE = r"""#!/bin/bash
cd "$FX_WORK" || exit 9
git fetch -q origin "$1" || { echo "::error::gate: cannot fetch $1"; exit 9; }
TIP=$(git rev-parse FETCH_HEAD)
git fetch -q origin master
changed=$(git diff --name-only origin/master "$TIP" | sort | tr '\n' ' ')
printf '%s\n' "$changed" >> "$FX_STATE/gates.log"
if [ -s "$FX_STATE/infra.script" ]; then
  first=$(head -1 "$FX_STATE/infra.script"); sed -i 1d "$FX_STATE/infra.script"
  if [ "$first" = infra ]; then echo "::error::check-disk-space: INFRASTRUCTURE -- full disk (/tmp)"; exit 1; fi
fi
bad=$(git diff --name-only origin/master "$TIP" | grep '^bad/' | head -1)
if [ -n "$bad" ]; then
  if [ -e "$FX_STATE/name-path" ]; then echo "::error::lint: $bad is wrong"; else echo "::error::tests: 1 failed"; fi
  exit 1
fi
if [ -e "$FX_STATE/squash" ]; then
  git checkout -q --detach origin/master
  git merge -q --squash "$TIP" >/dev/null
  if [ -s "$FX_STATE/squash-omit" ]; then while read -r p; do git rm -q --cached "$p"; rm -f "$p"; done < "$FX_STATE/squash-omit"; fi
  git -c user.name=g -c user.email=g@x commit -qm "squash of $1 (the branch contained merge commits)"
  git push -q origin HEAD:refs/heads/master || { echo "::error::push rejected"; exit 1; }
  git checkout -q master
else
  git push -q origin "$TIP":refs/heads/master || { echo "::error::push rejected"; exit 1; }
fi
echo "✅ Issue #0 merged into 'master' and verified: tests passed."
"""

TIMINGS_STUB = """#!/bin/bash
echo "$@" >> "$FX_STATE/timings.log"
"""


def sh(*cmd, cwd=None, check=True):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise AssertionError(f"{cmd} failed: {r.stdout}{r.stderr}")
    return r


class Fx:
    def __init__(self, root: Path, train=None):
        self.root = root
        self.origin, self.work, self.issues, self.state = root / "origin.git", root / "work", root / "issues", root / "state"
        self.state.mkdir()
        for k, v in {"ISSUE_DIR_PATH": str(self.issues), "XDG_STATE_HOME": str(root / "xdg"), "AUTOCODER_TRAIN_SCRATCH": str(root / "scratch"),
                     "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
                     "AUTOCODER_ISSUE_EVENTS": str(root / "events.jsonl"), "FX_WORK": str(self.work), "FX_STATE": str(self.state)}.items():
            os.environ[k] = v
        sh("git", "init", "-q", "--bare", str(self.origin))
        sh("git", "init", "-q", "-b", "master", str(self.work))
        (self.work / "README.md").write_text("base\n")
        sh("git", "add", "-A", cwd=self.work)
        sh("git", "commit", "-q", "-m", "init", cwd=self.work)
        sh("git", "remote", "add", "origin", str(self.origin), cwd=self.work)
        sh("git", "push", "-q", "origin", "master", cwd=self.work)
        sh("git", "fetch", "-q", "origin", cwd=self.work)
        sh("git", "update-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/master", cwd=self.work)
        (self.work / ".git/info/exclude").write_text(".autocoder.json\n")
        (root / "gate.sh").write_text(GATE)
        (root / "timings.sh").write_text(TIMINGS_STUB)
        self.train = {"gate": f"bash {root / 'gate.sh'} {{train}} {{sha}}", "gateLogDir": str(root / "gatelogs"),
                      "timingsCmd": f"bash {root / 'timings.sh'}", "size": 8, **(train or {})}
        self.write_config()

    def write_config(self):
        (self.work / ".autocoder.json").write_text(json.dumps({"issueSource": "file", "issueDir": str(self.issues), "train": self.train}))

    def rc(self):
        return R.load_run_config(self.work)

    def member(self, n, bad=False):
        """A READY issue whose branch adds files/m<n>.txt (and bad/m<n>.txt when bad)."""
        name = f"feature/m{n}"
        sh("git", "checkout", "-q", "-B", name, "origin/master", cwd=self.work)
        files = {f"files/m{n}.txt": f"{n}\n", **({f"bad/m{n}.txt": "x\n"} if bad else {})}
        for p, c in files.items():
            (self.work / p).parent.mkdir(parents=True, exist_ok=True)
            (self.work / p).write_text(c)
        sh("git", "add", "-A", cwd=self.work)
        sh("git", "commit", "-q", "-m", f"work {n}", cwd=self.work)
        sh("git", "push", "-q", "-f", "origin", name, cwd=self.work)
        sh("git", "checkout", "-q", "master", cwd=self.work)
        r = sh(sys.executable, str(ISSUES_FILE), "create", "--title", f"m{n}", "--body", "", "--label", "ready-for-review", cwd=self.work)
        issue = json.loads(r.stdout)["number"]
        sh(sys.executable, str(ISSUES_FILE), "comment", str(issue), "--body", f"READY on `{name}`", cwd=self.work)
        return issue

    def members(self, n, bad=()):
        return [self.member(i, bad=i in bad) for i in range(n)]

    def run(self, **kw):
        cyc = R.Cycle(self.rc(), log=lambda m: None)
        code, _ = cyc.run(**kw)
        return code, cyc

    def gates(self):
        p = self.state / "gates.log"
        return [ln.split() for ln in p.read_text().splitlines()] if p.exists() else []

    def landed(self, n):
        sh("git", "fetch", "-q", "origin", cwd=self.work)
        return R.tip_landed(self.rc().cfg, T.git(self.work, "rev-parse", f"origin/feature/m{n}").stdout.strip()) if sh(
            "git", "rev-parse", "--verify", "-q", f"origin/feature/m{n}", cwd=self.work, check=False).returncode == 0 else True

    def on_master(self, n):
        return (self.work / f"files/m{n}.txt").exists() or sh("git", "cat-file", "-e", f"origin/master:files/m{n}.txt", cwd=self.work, check=False).returncode == 0

    def state_of(self, issue):
        return json.loads(T.tracker(self.rc().cfg, "issue_get", str(issue)).stdout)["state"]

    def comments(self, issue):
        return "\n".join(c["body"] for c in T.ready_comments(json.loads(T.tracker(self.rc().cfg, "issue_get", str(issue)).stdout)))

    def dropped(self):
        p = self.rc().cfg.state_dir / "dropped.tsv"
        return [ln.split("\t") for ln in p.read_text().splitlines()] if p.exists() else []


@pytest.fixture
def fx(tmp_path):
    return Fx(tmp_path)


# ── the acceptance cases of the red-batch rules ─────────────────────────────────────────
def test_a_green_batch_of_eight_lands_in_one_gate(fx):
    issues = fx.members(8)
    code, cyc = fx.run()
    assert code == 0
    assert len(fx.gates()) == 1 and len(fx.gates()[0]) == 8
    assert all(fx.on_master(i) for i in range(8))
    assert [fx.state_of(i) for i in issues] == ["CLOSED"] * 8
    assert all("landed on `master`" in fx.comments(i) for i in issues)
    assert fx.dropped() == []
    assert R.State(fx.rc()).limit() == 9          # grew by one after a green batch


def test_one_bad_member_in_the_last_position_is_found_in_three_further_gates_and_seven_land(fx):
    issues = fx.members(8, bad={7})
    code, cyc = fx.run()
    assert code == 0
    assert 1 + 3 >= len(fx.gates())               # the full batch, then at most three partial gates
    assert [fx.on_master(i) for i in range(8)] == [True] * 7 + [False]
    assert [fx.state_of(i) for i in issues] == ["CLOSED"] * 7 + ["OPEN"]
    assert "returned" in fx.comments(issues[7])
    assert [d[0] for d in fx.dropped()] == [str(issues[7])]
    assert R.State(fx.rc()).limit() == 4          # halved after a red batch


@pytest.mark.parametrize("pos", [0, 3, 4])
def test_one_bad_member_anywhere_is_found_and_every_good_member_lands(fx, pos):
    issues = fx.members(8, bad={pos})
    fx.run()
    assert [fx.on_master(i) for i in range(8)] == [i != pos for i in range(8)]
    assert [d[0] for d in fx.dropped()] == [str(issues[pos])]
    assert len(fx.gates()) <= 1 + 6               # sound halving: never more than twice the depth


def test_two_bad_members_are_both_found_and_the_rest_land(fx):
    issues = fx.members(8, bad={1, 5})
    fx.run()
    assert [fx.on_master(i) for i in range(8)] == [i not in (1, 5) for i in range(8)]
    assert sorted(d[0] for d in fx.dropped()) == sorted(str(issues[i]) for i in (1, 5))
    assert {fx.state_of(issues[i]) for i in (1, 5)} == {"OPEN"}
    assert all(fx.state_of(issues[i]) == "CLOSED" for i in (0, 2, 3, 4, 6, 7))


def test_an_infrastructure_red_is_regated_once_and_nobody_is_dropped(fx):
    issues = fx.members(4)
    (fx.state / "infra.script").write_text("infra\n")
    fx.run()
    assert len(fx.gates()) == 2 and fx.gates()[0] == fx.gates()[1]     # the SAME set, once more
    assert fx.dropped() == []
    assert all(fx.on_master(i) for i in range(4)) and [fx.state_of(i) for i in issues] == ["CLOSED"] * 4


def test_two_infrastructure_rereds_end_the_cycle_with_everyone_back_in_the_queue_unfaulted(fx):
    issues = fx.members(4)
    (fx.state / "infra.script").write_text("infra\ninfra\n")
    code, _ = fx.run()
    assert code == 0 and len(fx.gates()) == 2            # never a third, never a bisect
    assert fx.dropped() == [] and not any(fx.on_master(i) for i in range(4))
    assert [fx.state_of(i) for i in issues] == ["OPEN"] * 4
    assert R.State(fx.rc()).limit() == 8                 # an infrastructure red says nothing about the batch size


# ── a hold-out re-gates the remaining members ───────────────────────────────────────────
def test_a_red_that_names_a_member_returns_it_and_regates_the_remaining_members(fx):
    issues = fx.members(5, bad={2})
    (fx.state / "name-path").write_text("")
    fx.run()
    gates = fx.gates()
    assert len(gates) == 2                                       # the full set, then the REMAINING four as a set
    assert "bad/m2.txt" in gates[0] and not any("m2" in f for f in gates[1]) and len(gates[1]) == 4
    assert [fx.on_master(i) for i in range(5)] == [True, True, False, True, True]
    assert [d[0] for d in fx.dropped()] == [str(issues[2])]
    assert "the one the failure names" in fx.comments(issues[2])


def test_a_path_every_member_touches_names_nobody(fx, tmp_path):
    fx.members(3)
    cyc = R.Cycle(fx.rc(), log=lambda m: None)
    members = [{"issue": str(i), "branch": f"feature/m{i}", "tip": T.git(fx.work, "rev-parse", f"origin/feature/m{i}").stdout.strip()} for i in range(3)]
    base = T.git(fx.work, "rev-parse", "origin/master").stdout.strip()
    assert cyc.named_members(base, members, "::error::tests: files/m1.txt differs") == [members[1]]
    assert cyc.named_members(base, members, "::error::x: README.md and files/m0.txt files/m1.txt files/m2.txt") == []


# ── member accounting survives a failed tracker call ────────────────────────────────────
def test_a_failed_tracker_call_does_not_change_the_member_set(fx, monkeypatch):
    issues = fx.members(4)
    real = T.tracker

    def flaky(cfg, *args, **kw):
        if args[0] in ("issue_comment", "issue_close"):
            raise RuntimeError("tracker is down")
        return real(cfg, *args, **kw)

    monkeypatch.setattr(T, "tracker", flaky)
    code, cyc = fx.run()
    assert code == 0 and len(fx.gates()) == 1
    assert all(fx.on_master(i) for i in range(4))                  # they landed, git says so
    assert sorted(cyc.landed_total) == sorted(str(i) for i in issues)
    st = R.State(fx.rc())
    assert len(st.pending()) >= 4                                   # the closes wait in the retry list
    monkeypatch.setattr(T, "tracker", real)
    assert R.Reporter(fx.rc(), st, lambda m: None).flush() == 0
    assert [fx.state_of(i) for i in issues] == ["CLOSED"] * 4
    assert st.pending() == []


def test_a_cycle_left_by_a_dead_process_is_reconciled_against_git(fx):
    issues = fx.members(2)
    cfg = fx.rc().cfg
    tips = [T.git(fx.work, "rev-parse", f"origin/feature/m{i}").stdout.strip() for i in range(2)]
    fx.land_branch = sh("git", "push", "-q", "origin", f"{tips[0]}:refs/heads/master", cwd=fx.work)   # member 0 landed, then the process died
    st = R.State(fx.rc())
    st.save_cycle({"started": "then", "members": [{"issue": str(issues[i]), "branch": f"feature/m{i}", "tip": tips[i], "status": "gating", "note": ""} for i in range(2)]})
    sh("git", "fetch", "-q", "origin", cwd=fx.work)
    cyc = R.Cycle(fx.rc(), log=lambda m: None)
    cyc.reconcile()
    assert fx.state_of(issues[0]) == "CLOSED" and fx.state_of(issues[1]) == "OPEN"
    assert st.cycle() == {} and not (cfg.state_dir / "current.tsv").exists()


# ── adaptive batch size ─────────────────────────────────────────────────────────────────
def test_the_limit_starts_at_eight_grows_after_green_halves_after_red_and_keeps_its_floor_and_ceiling(fx):
    st = R.State(fx.rc())
    assert st.limit() == 8
    assert st.record_batch(8, "green") == (8, 9)
    assert st.record_batch(9, "red") == (9, 4)
    assert st.record_batch(4, "red") == (4, 2)
    assert st.record_batch(2, "red") == (2, 2)                     # floor
    assert st.record_batch(2, "abort") == (2, 2)
    fx.train.update(batchMax=3)
    fx.write_config()
    st = R.State(fx.rc())
    st.record_batch(2, "green"); st.record_batch(3, "green")
    assert st.limit() == 3                                         # ceiling
    assert st.batch()["history"][0]["verdict"] == "green"


def test_the_plan_is_cut_at_the_limit(fx):
    fx.members(6)
    fx.train.update(batchStart=3)
    fx.write_config()
    fx.run()
    assert [len(g) for g in fx.gates()] == [3]


# ── lease, preflight, regeneration, timings ─────────────────────────────────────────────
def test_a_second_train_is_refused_while_the_lease_is_held(fx):
    held = R.Lease(R.State(fx.rc()))
    assert held.acquire()[0]
    fx.members(2)
    code, _ = fx.run()
    assert code == 1 and fx.gates() == []
    held.release()
    assert fx.run()[0] == 0 and len(fx.gates()) == 1


def test_a_failing_preflight_refuses_before_anything_is_planned(fx):
    fx.members(2)
    fx.train["hooks"] = {"preflight": "echo 'node_modules is stale: npm ci'; exit 1"}
    fx.write_config()
    code, _ = fx.run()
    assert code == 1 and fx.gates() == [] and not (fx.root / "scratch").exists()


def test_the_regeneration_hook_runs_on_the_assembled_tree_and_is_committed(fx):
    fx.members(2)
    fx.train["hooks"] = {"regenerate": "ls files | sort | tr '\\n' ' ' > generated.txt"}
    fx.write_config()
    fx.run()
    assert sh("git", "show", "origin/master:generated.txt", cwd=fx.work).stdout.split() == ["m0.txt", "m1.txt"]
    assert "generated.txt" in fx.gates()[0]


def test_a_failing_regeneration_blames_nobody_and_gates_nothing(fx):
    issues = fx.members(2)
    fx.train["hooks"] = {"regenerate": "echo 'generator exploded'; exit 3"}
    fx.write_config()
    code, _ = fx.run()
    assert code == 0 and fx.gates() == [] and fx.dropped() == []
    assert [fx.state_of(i) for i in issues] == ["OPEN", "OPEN"]


def tips(fx, n):
    return [T.git(fx.work, "rev-parse", f"origin/feature/m{i}").stdout.strip() for i in range(n)]


def test_a_squash_landing_closes_every_member_by_its_content(fx):
    """4.38.0+ lands a train as ONE squash commit, so no member tip is an ancestor of master and no member
    commit is patch-equivalent to one there; the content proof closes them."""
    issues = fx.members(3)
    before = tips(fx, 3)
    (fx.state / "squash").write_text("")
    code, cyc = fx.run()
    assert code == 0 and len(fx.gates()) == 1
    sh("git", "fetch", "-q", "origin", cwd=fx.work)
    assert all(sh("git", "merge-base", "--is-ancestor", t, "origin/master", cwd=fx.work, check=False).returncode != 0 for t in before)
    assert all(T.landing_proof(fx.rc().cfg, t) == "content" for t in before)
    assert [fx.state_of(i) for i in issues] == ["CLOSED"] * 3
    assert all("landing proof: content" in fx.comments(i) for i in issues)
    assert all(sh("git", "rev-parse", "--verify", "-q", f"origin/feature/m{n}", cwd=fx.work, check=False).returncode != 0 for n in range(3))
    assert fx.dropped() == [] and R.State(fx.rc()).cycle() == {}


def test_a_squash_landing_that_lacks_a_members_work_leaves_that_member_open_and_in_the_queue(fx):
    issues = fx.members(3)
    (fx.state / "squash").write_text("")
    (fx.state / "squash-omit").write_text("files/m1.txt\n")
    code, cyc = fx.run()
    assert code == 0
    assert [fx.state_of(i) for i in issues] == ["CLOSED", "OPEN", "CLOSED"]
    assert "landed on" not in fx.comments(issues[1])
    assert sh("git", "rev-parse", "--verify", "-q", "origin/feature/m1", cwd=fx.work, check=False).returncode == 0
    assert fx.dropped() == [] and R.State(fx.rc()).cycle() == {}
    first = T.plan_queue(fx.rc().cfg)[0]
    assert str(first["issue"]) == str(issues[1]) and first["state"] in ("queue", "launched")


def test_the_landed_hook_runs_once_after_a_landing_with_the_landing_in_its_environment(fx):
    issues = fx.members(2)
    base = T.git(fx.work, "rev-parse", "origin/master").stdout.strip()
    before = tips(fx, 2)
    fx.train["hooks"] = {"landed": 'printf "%s %s %s %s\\n" "$AUTOCODER_TRAIN_BRANCH" "$AUTOCODER_TRAIN_LANDED" "$AUTOCODER_TRAIN_BASE" "$AUTOCODER_TRAIN_INTEGRATION" >> "$FX_STATE/landed.log"; printf "%s\\n" "$AUTOCODER_TRAIN_MEMBERS" >> "$FX_STATE/landed.log"; pwd >> "$FX_STATE/landed.log"'}
    fx.write_config()
    fx.run()
    sh("git", "fetch", "-q", "origin", cwd=fx.work)
    lines = (fx.state / "landed.log").read_text().splitlines()
    head = lines[0].split()
    assert head[0].startswith("train/") and head[1] == T.git(fx.work, "rev-parse", "origin/master").stdout.strip() and head[2] == base and head[3] == "master"
    assert lines[1:3] == [f"{issues[0]}\t{before[0]}\tfeature/m0", f"{issues[1]}\t{before[1]}\tfeature/m1"]
    assert lines[3] == str(fx.work.resolve()) and len(lines) == 4


def test_a_failing_landed_hook_cannot_unland_and_is_reported(fx):
    issues = fx.members(2)
    report = fx.member(9)
    fx.train["hooks"] = {"landed": "echo 'upstream push refused'; exit 4"}
    fx.train["reportIssue"] = str(report)
    fx.write_config()
    code, _ = fx.run()
    assert code == 0 and [fx.state_of(i) for i in issues] == ["CLOSED", "CLOSED"]
    assert "`landed` hook exited 4" in fx.comments(report) and "upstream push refused" in fx.comments(report)


def test_the_landed_hook_runs_on_a_partial_landing_and_names_the_members_apart(fx):
    issues = fx.members(2)
    before = tips(fx, 2)
    (fx.state / "squash").write_text("")
    (fx.state / "squash-omit").write_text("files/m0.txt\n")
    fx.train["hooks"] = {"landed": 'printf "landed=%s\\nunlanded=%s\\n" "$AUTOCODER_TRAIN_MEMBERS" "$AUTOCODER_TRAIN_UNLANDED" >> "$FX_STATE/landed.log"'}
    fx.write_config()
    fx.run()
    assert (fx.state / "landed.log").read_text().splitlines() == [f"landed={issues[1]}\t{before[1]}\tfeature/m1", f"unlanded={issues[0]}\t{before[0]}\tfeature/m0"]


def test_timing_rows_go_through_the_writer(fx):
    fx.members(3)
    fx.run()
    rows = (fx.state / "timings.log").read_text().splitlines()
    assert sum(r.startswith("change --issue") and "--event batched" in r for r in rows) == 3
    assert sum(r.startswith("change --issue") and "--event landed" in r for r in rows) == 3
    batch = [r for r in rows if r.startswith("batch ")]
    assert len(batch) == 1 and "--verdict green" in batch[0] and "--members" in batch[0]


def test_the_gate_command_defaults_to_the_plugin_gate_contract(fx):
    fx.train.pop("gate")
    fx.train.update(gateIssue="42", testCmd="make test")
    fx.write_config()
    cmd = R.Cycle(fx.rc(), log=lambda m: None).gate_command("train/x", "abc123")
    assert "merge-to-integration.sh" in cmd and "--feature train/x" in cmd and "--feature-sha abc123" in cmd
    assert "--issue 42" in cmd and "--integration master" in cmd and "--test-cmd 'make test'" in cmd


def test_the_gate_budget_leaves_undecided_members_in_the_queue(fx):
    issues = fx.members(8, bad={0})
    fx.train["maxGates"] = 2
    fx.write_config()
    fx.run()
    assert len(fx.gates()) <= 3 and fx.dropped() == []             # nobody faulted for want of budget
    assert any(fx.state_of(i) == "OPEN" for i in issues)


def test_the_cli_reports_and_pins_the_limit(fx):
    def run(*a):
        return sh(sys.executable, str(CLI), "--repo", str(fx.work), *a).stdout.strip()
    assert run("limit") == "8"
    assert run("limit", "--set", "50") == "16"                     # clamped to the ceiling
    assert "batch limit 16" in run("status")
    assert "cleared" in run("abandon")


def test_the_publisher_batch_marker_brackets_a_cycle(fx, tmp_path, monkeypatch):
    stub = tmp_path / "publisher.sh"
    stub.write_text('#!/bin/bash\necho "$1 $2 $3" >> "$FX_STATE/publisher.log"\n')
    monkeypatch.setenv("AUTOCODER_TRAIN_PUBLISHER", str(stub))
    fx.members(2)
    fx.run()
    rows = (fx.state / "publisher.log").read_text().splitlines()
    assert rows[0].startswith("batch-begin --pid") and rows[-1].startswith("batch-end --force")
    assert len(fx.gates()) == 1                                    # the cycle itself pushes nothing to the integration branch
