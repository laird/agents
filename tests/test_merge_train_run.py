"""merge train run (train_run.py, merge-train-run.py): assembly, the gate, publish and close-out, and the
red-batch rules, over a real git fixture repo, the file issue backend and a SCRIPTED gate.

The scripted gate (`gate.sh`, written per fixture) stands in for merge-to-integration.sh and keeps its
contract: exit 0 plus a `merged into` line mean the tree landed (here: a fast-forward push to master);
anything else is red, with an `::error::` line. A member is bad when it adds a file under `bad/`; the red
line names no path unless the fixture asks it to. `infra.script` lists outcomes consumed one per gate
(`infra` = an INFRASTRUCTURE refusal). A tree with no change against master gets the real gate's empty-rebase
line ("dropped every commit as already upstream") and exit 1, as merge-to-integration.sh prints it. `gates.log` records, per gate, the files the tree adds to master.
With `squash` present the gate lands the way merge-to-integration.sh lands a branch that holds merge
commits (every train does): ONE squash commit on master, no member tip in its history; `squash-omit`
lists paths left out of that commit (a landing that did not carry a member's work).
"""

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
printf '%s|%s\n' "${AUTOCODER_LANDING_BATCH:-}" "${AUTOCODER_LANDING_MEMBERS:-}" >> "$FX_STATE/gate-env.log"
printf '%s\n' "${AUTOCODER_LANDING_REPO:-}" >> "$FX_STATE/gate-repo.log"
if [ -s "$FX_STATE/infra.script" ]; then
  first=$(head -1 "$FX_STATE/infra.script"); sed -i 1d "$FX_STATE/infra.script"
  # pass: no scripted outcome for this gate (the line is consumed; the gate judges the tree as usual)
  if [ "$first" = pass ]; then :; fi
  # flaky: the failing files passed on a second run of the same tree (merge-to-integration.sh's FLAKY refusal)
  if [ "$first" = flaky ]; then
    echo "❌ Tests fail on the integrated tree 73ed0986 (1 named failure(s))."
    echo "   Re-running the files that failed on the same tree first: AUTOCODER_GATE_RETEST_FILES=\"t_flaky.test\" (a pass means the failure did not reproduce: flaky, nobody's)"
    echo "merge-to-integration: FLAKY -- t_flaky.test failed on the integrated tree 73ed0986 and passed on a second run of the same tree: the failure did not reproduce, so it is nobody's. NOT pushing."
    echo "::error::FLAKY: \`t_flaky.test\` failed on the integrated tree 73ed0986 and passed on a second run of the same tree"
    exit 3
  fi
  if [ "$first" = infra ]; then
    # a stage's refusal: the real gate's EXIT trap records its own gate-end, so this stub does too
    printf '{"v":1,"ts":"%s","issue":0,"event":"gate-end","detail":{"outcome":"escalated"}}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$AUTOCODER_ISSUE_EVENTS"
    echo "::error::check-disk-space: INFRASTRUCTURE -- full disk (/tmp)"; exit 1
  fi
  # killed: the whole gate dies by SIGKILL (an OOM kill of its scope) with no verdict line and no trap
  if [ "$first" = killed ]; then kill -KILL $$; fi
  # red-base: the plugin's refusal on a red base (the files that failed on the integrated tree fail on master alone too)
  if [ "$first" = red-base ]; then
    echo "❌ Tests fail on the integrated tree 73ed0986 (1 named failure(s))."
    echo "   t_shared.test: fails on origin/master too (red base, not this change's)"
    echo "merge-to-integration: RED-BASE -- origin/master (c44669ae) fails alone too with the same 1 named failure(s) in t_shared.test: red master, not this change's."
    echo "❌ origin/master fails alone too (tree 8eda80f4, the same 1 named failure(s)), and AUTOCODER_MERGE_ON_RED_BASE=0 forbids landing on a red base. NOT pushing."
    exit 2
  fi
  # retest-red-base (#7130): no RED-BASE line (the gate's own comparison of the two runs' named failures
  # disagreed: its summary lines differ only by their wall time), yet every retested file fails on the base too
  if [ "$first" = retest-red-base ]; then
    echo "❌ The integrated tree 73ed0986 names failure(s) origin/master alone does not, so this change broke it (at least these). NOT pushing."
    echo "   t_shared.test: fails on origin/master too (red base, not this change's)"
    echo "   this change only: ::error::run-gate-stages: FAIL (stage runner rc 1; fail wall 1084.7 s; failed: db-tests)"
    echo "   base only:        ::error::run-gate-stages: FAIL (stage runner rc 1; fail wall 78.8 s; failed: db-tests)"
    echo "::error::tests fail on the integrated tree 73ed0986 with failure(s) origin/master alone (tree 8eda80f4) does not have, so this change broke it"
    exit 2
  fi
  # retest-mixed (#7130): one retested file is the base's, another is the change's: the change's red, attributed as before
  if [ "$first" = retest-mixed ]; then
    echo "   t_shared.test: fails on origin/master too (red base, not this change's)"
    echo "   t_mine.test: passes on origin/master (this change's)"
    echo "::error::tests: 1 failed"
    exit 2
  fi
  # land-red-base: the plugin landed anyway on a red base (the default once a sentinel proved green)
  if [ "$first" = land-red-base ]; then
    echo "merge-to-integration: RED-BASE -- origin/master (c44669ae) fails alone too with the same 1 named failure(s) in t_shared.test: red master, not this change's."
    echo "⚠️  origin/master fails alone too (tree 8eda80f4) with the same 1 named failure(s): the integration branch is red independent of this change."
  fi
fi
if [ -z "$changed" ]; then
  # merge-to-integration.sh's own line for a rebase that drops every commit as already upstream
  echo "❌ Rebasing $1 (${TIP:0:8}) dropped every commit as already upstream, but origin/master ($(git rev-parse --short=8 origin/master)) does not carry its change. NOT closing."
  exit 1
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
  PUB=$(git rev-parse HEAD)
  git push -q origin HEAD:refs/heads/master || { echo "::error::push rejected"; exit 1; }
  git checkout -q master
else
  git push -q origin "$TIP":refs/heads/master || { echo "::error::push rejected"; exit 1; }
  PUB=$TIP
fi
echo "✅ Issue #0 merged into 'master' and verified: tests passed on the published tree ${PUB:0:8}."
"""

TIMINGS_STUB = """#!/bin/bash
echo "$@" >> "$FX_STATE/timings.log"
echo "${AUTOCODER_LANDING_REPO:-}" >> "$FX_STATE/timings-repo.log"
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
                      "timingsCmd": f"bash {root / 'timings.sh'}", "size": 8, "branchOwnership": "any", **(train or {})}   # fixture branches carry no issue number
        self.write_config()

    def write_config(self):
        (self.work / ".autocoder.json").write_text(json.dumps({"issueSource": "file", "issueDir": str(self.issues), "train": self.train}))

    def rc(self):
        return R.load_run_config(self.work)

    def member(self, n, bad=False, labels=(), title=None, message=None):
        """A READY issue whose branch adds files/m<n>.txt (and bad/m<n>.txt when bad); `labels` beside ready-for-review."""
        name = f"feature/m{n}"
        sh("git", "checkout", "-q", "-B", name, "origin/master", cwd=self.work)
        files = {f"files/m{n}.txt": f"{n}\n", **({f"bad/m{n}.txt": "x\n"} if bad else {})}
        for p, c in files.items():
            (self.work / p).parent.mkdir(parents=True, exist_ok=True)
            (self.work / p).write_text(c)
        sh("git", "add", "-A", cwd=self.work)
        sh("git", "commit", "-q", "-m", message or f"work {n}", cwd=self.work)
        sh("git", "push", "-q", "-f", "origin", name, cwd=self.work)
        sh("git", "checkout", "-q", "master", cwd=self.work)
        r = sh(sys.executable, str(ISSUES_FILE), "create", "--title", title or f"m{n}", "--body", "", "--label", "ready-for-review", *[x for lb in labels for x in ("--label", lb)], cwd=self.work)
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


def test_the_gate_learns_the_batch_id_and_members_it_gates(fx):
    # merge-to-integration.sh writes its landing-timings batch row under this id with these members, so a
    # train's gate is one batch row, not a solo row of the gate issue beside the train's
    issues = fx.members(3)
    code, _ = fx.run()
    assert code == 0
    envs = (fx.state / "gate-env.log").read_text().splitlines()
    assert len(envs) == 1
    batch, members = envs[0].split("|")
    assert re.fullmatch(r"train-\d{8}T\d{6}Z-1", batch) and members == ",".join(map(str, issues))


def test_each_bisection_gate_names_only_the_members_it_gates(fx):
    # the record keeps the held-out half at `gating`, so the members come from the gated set, never the record
    issues = [str(i) for i in fx.members(8, bad={7})]
    code, _ = fx.run()
    assert code == 0
    gated = [ln.split("|")[1] for ln in (fx.state / "gate-env.log").read_text().splitlines()]
    assert gated[0] == ",".join(issues)
    assert all(set(g.split(",")) < set(issues) for g in gated[1:])          # every later gate is a strict subset
    assert len(gated) >= 2 and issues[7] not in gated[-1].split(",")         # the last gate is a good set; the culprit is found by elimination
    assert all(sorted(g.split(","), key=int) == g.split(",") for g in gated)


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


def test_a_flaky_red_is_regated_once_and_everyone_lands_with_the_limit_untouched(fx):
    # the gate re-ran the failing files on the same tree and they passed: nobody's red, the same set once more
    issues = fx.members(4)
    (fx.state / "infra.script").write_text("flaky\n")
    code, cyc = fx.run()
    assert code == 0
    assert len(fx.gates()) == 2 and fx.gates()[0] == fx.gates()[1]     # the SAME set, once more; never a bisection
    assert fx.dropped() == [] and cyc.returned_total == []
    assert all(fx.on_master(i) for i in range(4)) and [fx.state_of(i) for i in issues] == ["CLOSED"] * 4
    assert R.State(fx.rc()).limit() == 9                                 # the landing was green: the limit grew as after any green
    rows = [ln.split() for ln in (fx.state / "timings.log").read_text().splitlines()]
    assert any(r[:1] == ["batch"] and "aborted" in r and "flaky" in r for r in rows)   # the wasted pass is a flaky row, not a red


def test_two_flaky_reds_end_the_cycle_with_everyone_in_the_queue_unfaulted(fx):
    issues = fx.members(4)
    report = fx.member(9)
    fx.train["reportIssue"] = str(report)
    fx.write_config()
    (fx.state / "infra.script").write_text("flaky\nflaky\n")
    code, cyc = fx.run()
    assert code == 0 and len(fx.gates()) == 2            # never a third, never a bisect
    assert fx.dropped() == [] and not any(fx.on_master(i) for i in range(4))
    assert [fx.state_of(i) for i in issues] == ["OPEN"] * 4
    assert cyc.returned_total == []
    assert R.State(fx.rc()).limit() == 8                 # a flaky red says nothing about the batch size
    note = fx.comments(report)
    assert "flaky red twice" in note and "t_flaky.test" in note and "file the flake" in note


def test_an_infrastructure_red_inside_a_bisection_is_not_the_red_a_later_return_cites(fx):
    # the set is red for a bad member; the first half's gate is refused as INFRASTRUCTURE, re-gated green; the bad
    # member is then red by inference and its return must cite the set's red, never the INFRASTRUCTURE line (#382)
    issues = fx.members(3, bad={2})
    (fx.state / "infra.script").write_text("pass\ninfra\n")
    code, _ = fx.run()
    assert code == 0
    gated = [ln.split("|")[1] for ln in (fx.state / "gate-env.log").read_text().splitlines()]
    assert len(gated) == 3 and gated[1] == gated[2] == ",".join(str(i) for i in issues[:2])   # the half: infra, then green
    assert [fx.on_master(i) for i in range(3)] == [True, True, False]
    assert fx.state_of(issues[2]) == "OPEN"
    returned = fx.comments(issues[2])
    assert "returned" in returned and "tests: 1 failed" in returned and "INFRASTRUCTURE" not in returned
    assert [d[0] for d in fx.dropped()] == [str(issues[2])]


def test_a_red_base_refusal_ends_the_cycle_with_everyone_in_the_queue_unfaulted_and_names_the_integration_branch(fx):
    issues = fx.members(4)
    report = fx.member(9)
    fx.train["reportIssue"] = str(report)
    fx.write_config()
    (fx.state / "infra.script").write_text("red-base\n")
    code, _ = fx.run()
    assert code == 0 and len(fx.gates()) == 1            # never a re-gate, never a bisect: the same base fails the same way
    assert fx.dropped() == [] and not any(fx.on_master(i) for i in range(4))
    assert [fx.state_of(i) for i in issues] == ["OPEN"] * 4
    assert R.State(fx.rc()).limit() == 8                 # a red base says nothing about the batch size
    note = fx.comments(report)
    assert "red `master`, not a member's" in note and "nobody dropped, held out or re-gated" in note
    assert "RED-BASE -- origin/master" in note and "Open or cite the issue for red `master`" in note
    assert all("returned:" not in fx.comments(i) for i in issues)


def test_while_a_red_master_is_open_a_cycle_lands_only_the_hotfix_and_the_hold_lifts_when_the_red_closes(fx):
    """#7179 (ask 4): a red tracker state, one ordinary READY and one hotfix: only the hotfix lands; the ordinary member
    is told `held: red master #N` once and stays in the queue unfaulted; after the red closes, the next cycle lands it."""
    fx.train["redMaster"] = {"label": "P0", "titlePrefix": "Red master:"}
    fx.write_config()
    r = sh(sys.executable, str(ISSUES_FILE), "create", "--title", "Red master: tests/x.test.ts fails at abcdef12", "--body", "", "--label", "P0", "--label", "bug", cwd=fx.work)
    red = json.loads(r.stdout)["number"]
    ordinary = fx.member(0)
    hot = fx.member(1, labels=("hotfix",))
    code, _ = fx.run()
    assert code == 0
    assert fx.on_master(1) and not fx.on_master(0)
    assert [fx.state_of(hot), fx.state_of(ordinary)] == ["CLOSED", "OPEN"]
    assert fx.dropped() == []
    note = fx.comments(ordinary)
    assert f"held: red master #{red}" in note and "returned:" not in note
    code, _ = fx.run()                                    # a second cycle while the red is open: told once, still held
    assert not fx.on_master(0) and fx.comments(ordinary).count("held: red master") == 1
    sh(sys.executable, str(ISSUES_FILE), "close", str(red), "--comment", "fixed", cwd=fx.work)
    code, _ = fx.run()
    assert code == 0 and fx.on_master(0) and fx.state_of(ordinary) == "CLOSED"


def test_release_on_landed_lifts_the_hold_on_the_next_cycle_once_the_hotfix_gate_was_green(fx):
    """#428: the first cycle still holds the ordinary READY (the fix is not on the tip yet) and lands only the
    hotfix. The next cycle sees that commit on the tip with a green gate log, logs the lift naming the sha,
    and lands the ordinary member without the red issue closing."""
    fx.train["redMaster"] = {"label": "P0", "titlePrefix": "Red master:"}
    fx.train["redHold"] = {"releaseOn": "landed"}
    fx.write_config()
    r = sh(sys.executable, str(ISSUES_FILE), "create", "--title", "Red master: tests/x.test.ts fails at abcdef12", "--body", "", "--label", "P0", "--label", "bug", cwd=fx.work)
    red = json.loads(r.stdout)["number"]
    ordinary = fx.member(0)
    hot = fx.member(1, labels=("hotfix",), message=f"hotfix/m1: fix #{red}")
    logs = []
    cyc = R.Cycle(fx.rc(), log=logs.append)
    code, _ = cyc.run()
    assert code == 0 and fx.on_master(1) and not fx.on_master(0)
    assert [fx.state_of(hot), fx.state_of(ordinary)] == ["CLOSED", "OPEN"]
    assert not any(ln.startswith("hold lifted:") for ln in logs)
    logs.clear()
    code, _ = cyc.run()
    assert code == 0 and fx.on_master(0) and fx.state_of(ordinary) == "CLOSED"
    lifted = [ln for ln in logs if ln.startswith("hold lifted: fix landed ") and ln.endswith("(CI verdict pending)")]
    assert len(lifted) == 1
    sha = lifted[0].split("fix landed ", 1)[1].split(" ", 1)[0]
    subjects = sh("git", "log", "-n", "20", "--format=%H %s", "origin/master", cwd=fx.work).stdout
    assert f"{sha} hotfix/m1: fix #{red}" in subjects


def _ci_gh(fx, runs):
    """A `gh` that prints `runs` for `run list` and fails anything else. Returns the saved PATH."""
    bindir = fx.root / "bin"
    bindir.mkdir(exist_ok=True)
    (fx.state / "ci-runs.json").write_text(json.dumps(runs))
    (bindir / "gh").write_text(
        "#!/bin/bash\n"
        "if [ \"$1\" = run ] && [ \"$2\" = list ]; then cat \"$FX_STATE/ci-runs.json\"; exit 0; fi\n"
        "echo \"unexpected gh $*\" >&2; exit 1\n")
    os.chmod(bindir / "gh", 0o755)
    saved = os.environ.get("PATH", "")
    os.environ["PATH"] = str(bindir) + os.pathsep + saved
    return saved


def _lifted_red(fx, *, close_on_green=None, body=""):
    """One cycle lands the hotfix and leaves the ordinary READY held, then lifted on the next plan (#428)."""
    fx.train["redMaster"] = {"label": "P0", "titlePrefix": "Red master:"}
    hold = {"releaseOn": "landed"}
    if close_on_green is not None:
        hold["closeOnGreenCi"] = close_on_green
    fx.train["redHold"] = hold
    fx.write_config()
    r = sh(sys.executable, str(ISSUES_FILE), "create", "--title", "Red master: tests/x.test.ts fails at abcdef12",
           "--body", body, "--label", "P0", "--label", "bug", cwd=fx.work)
    red = json.loads(r.stdout)["number"]
    ordinary = fx.member(0)
    fx.member(1, labels=("hotfix",), message=f"hotfix/m1: fix #{red}")
    code, _ = R.Cycle(fx.rc(), log=lambda m: None).run()
    assert code == 0 and fx.on_master(1) and not fx.on_master(0) and fx.state_of(red) == "OPEN"
    return red, ordinary


def _tick(fx, runs):
    saved = _ci_gh(fx, runs)
    logs = []
    try:
        verdict = R.Daemon(fx.rc(), log=logs.append, interval=0, once=True, sleep=lambda s: None).tick()
    finally:
        os.environ["PATH"] = saved
    return verdict, logs


def test_no_ci_verdict_yet_leaves_the_lifted_hold_up_and_the_ordinary_member_lands(fx):
    """#429: a run still in progress is not a verdict. The lift stands and the daemon plans the queue."""
    red, ordinary = _lifted_red(fx)
    verdict, logs = _tick(fx, [{"databaseId": 42, "conclusion": "", "name": "CI", "status": "in_progress", "headBranch": "master"}])
    assert verdict == "cycle:0:planned"
    assert fx.on_master(0) and fx.state_of(ordinary) == "CLOSED" and fx.state_of(red) == "OPEN"
    assert any("CI verdict pending" in ln for ln in logs)
    assert not any(ln.startswith("hold back:") for ln in logs)


def test_a_red_ci_verdict_on_the_lifted_tip_puts_the_hold_back(fx):
    """#429: a red run on the fix tip (the red names no job, so every run counts) re-holds the queue."""
    red, ordinary = _lifted_red(fx)
    runs = [{"databaseId": 42, "conclusion": "failure", "name": "CI", "status": "completed", "headBranch": "master"}]
    verdict, logs = _tick(fx, runs)
    assert verdict == "idle"
    assert not fx.on_master(0) and fx.state_of(ordinary) == "OPEN" and fx.state_of(red) == "OPEN"
    assert any(ln.startswith("hold back: CI red on ") and "(run 42)" in ln for ln in logs)
    rows = T.plan_queue(fx.rc().cfg)
    assert rows and {r["issue"]: r["state"] for r in rows}[ordinary] == "held"
    assert "hold back: CI red on " in T.status_line(rows, when="W") and "(run 42)" in T.status_line(rows, when="W")
    held = next(r for r in rows if r["issue"] == ordinary)
    assert "until CI on that landed tip is green" in held["note"]


def test_a_completed_red_run_puts_the_hold_back_while_another_run_is_still_going(fx):
    """A sibling workflow still in progress must not hide a completed red (#429)."""
    red, ordinary = _lifted_red(fx)
    runs = [
        {"databaseId": 42, "conclusion": "failure", "name": "test", "status": "completed", "headBranch": "master"},
        {"databaseId": 43, "conclusion": "", "name": "deploy", "status": "in_progress", "headBranch": "master"},
    ]
    verdict, logs = _tick(fx, runs)
    assert verdict == "idle" and not fx.on_master(0) and fx.state_of(red) == "OPEN"
    assert any("(run 42)" in ln and ln.startswith("hold back:") for ln in logs)


def test_a_later_named_job_still_red_puts_the_hold_back(fx):
    """ci-watch names every failed job. A green first job must not close the issue while a later one is red."""
    red, ordinary = _lifted_red(fx, close_on_green=True, body="job `unit`\njob `lint`\n")
    runs = [{"databaseId": 11, "conclusion": "failure", "name": "CI", "status": "completed", "headBranch": "master",
             "jobs": [{"name": "unit", "status": "completed", "conclusion": "success"},
                      {"name": "lint", "status": "completed", "conclusion": "failure"}]}]
    verdict, logs = _tick(fx, runs)
    assert verdict == "idle" and not fx.on_master(0) and fx.state_of(red) == "OPEN" and fx.state_of(ordinary) == "OPEN"
    assert any("job `lint`" in ln for ln in logs)
    assert "run 11" not in fx.comments(red)


def test_a_red_ci_on_a_different_job_does_not_put_the_hold_back(fx):
    """The red names `unit`. A red `lint` with `unit` green is not that job, so the lift stands (#429)."""
    red, ordinary = _lifted_red(fx, body="ci-job: unit\n")
    runs = [{"databaseId": 9, "conclusion": "failure", "name": "CI", "status": "completed", "headBranch": "master",
             "jobs": [{"name": "lint", "status": "completed", "conclusion": "failure"},
                      {"name": "unit", "status": "completed", "conclusion": "success"}]}]
    verdict, logs = _tick(fx, runs)
    assert verdict == "cycle:0:planned"
    assert fx.on_master(0) and fx.state_of(red) == "OPEN"
    assert not any(ln.startswith("hold back:") for ln in logs)
    assert any("stays open (closeOnGreenCi false)" in ln for ln in logs)


def test_a_red_ci_on_the_job_the_red_named_puts_the_hold_back(fx):
    red, ordinary = _lifted_red(fx, body="ci-job: unit\n")
    runs = [{"databaseId": 11, "conclusion": "success", "name": "CI", "status": "completed", "headBranch": "master",
             "jobs": [{"name": "lint", "status": "completed", "conclusion": "success"},
                      {"name": "unit", "status": "completed", "conclusion": "failure"}]}]
    verdict, logs = _tick(fx, runs)
    assert verdict == "idle" and not fx.on_master(0) and fx.state_of(red) == "OPEN"
    assert any("(run 11, job `unit`)" in ln for ln in logs)
    assert "job `unit`" in T.status_line(T.plan_queue(fx.rc().cfg), when="W")


def test_a_green_ci_verdict_leaves_the_tracking_issue_open_by_default(fx):
    red, ordinary = _lifted_red(fx)
    runs = [{"databaseId": 77, "conclusion": "success", "name": "CI", "status": "completed", "headBranch": "master"}]
    verdict, logs = _tick(fx, runs)
    assert verdict == "cycle:0:planned"
    assert fx.on_master(0) and fx.state_of(red) == "OPEN"
    assert "run 77" not in fx.comments(red)
    assert any("stays open (closeOnGreenCi false)" in ln for ln in logs)
    fx.member(2)   # a READY that arrives after the verdict: the status line must not still say pending
    line = T.status_line(T.plan_queue(fx.rc().cfg), when="W")
    assert "CI green, run 77" in line and "CI verdict pending" not in line


def test_a_green_ci_verdict_closes_the_tracking_issue_when_close_on_green_ci_is_set(fx):
    red, ordinary = _lifted_red(fx, close_on_green=True)
    runs = [{"databaseId": 77, "conclusion": "success", "name": "CI", "status": "completed", "headBranch": "master"}]
    verdict, logs = _tick(fx, runs)
    assert verdict == "cycle:0:planned"
    assert fx.state_of(red) == "CLOSED" and "run 77" in fx.comments(red) and "`CI`" in fx.comments(red)
    assert any(f"closed #{red}" in ln for ln in logs)


def _two_reds_one_hotfix(fx, *, close_on_green=True, bodies=("", "")):
    """Two open reds whose hotfix commit cites both, so they share one lifted sha."""
    fx.train["redMaster"] = {"label": "P0", "titlePrefix": "Red master:"}
    fx.train["redHold"] = {"releaseOn": "landed", "closeOnGreenCi": close_on_green}
    fx.write_config()
    reds = []
    for name, body in zip(("a", "b"), bodies):
        r = sh(sys.executable, str(ISSUES_FILE), "create", "--title", f"Red master: tests/{name}.test.ts fails at abcdef12",
               "--body", body, "--label", "P0", "--label", "bug", cwd=fx.work)
        reds.append(json.loads(r.stdout)["number"])
    ordinary = fx.member(0)
    fx.member(1, labels=("hotfix",), message=f"hotfix/m1: fix #{reds[0]} #{reds[1]}")
    code, _ = R.Cycle(fx.rc(), log=lambda m: None).run()
    assert code == 0 and fx.on_master(1) and not fx.on_master(0)
    assert fx.state_of(reds[0]) == "OPEN" and fx.state_of(reds[1]) == "OPEN"
    return reds[0], reds[1], ordinary


def test_a_green_ci_closes_every_red_the_hotfix_cites(fx):
    """One sha, two open reds. Recording the verdict on the first must not skip the second (#429)."""
    red_a, red_b, ordinary = _two_reds_one_hotfix(fx)
    runs = [{"databaseId": 77, "conclusion": "success", "name": "CI", "status": "completed", "headBranch": "master"}]
    verdict, logs = _tick(fx, runs)
    assert verdict == "cycle:0:planned" and fx.on_master(0) and fx.state_of(ordinary) == "CLOSED"
    assert fx.state_of(red_a) == "CLOSED" and fx.state_of(red_b) == "CLOSED"
    assert "run 77" in fx.comments(red_a) and "run 77" in fx.comments(red_b)
    assert any(f"closed #{red_a}" in ln for ln in logs) and any(f"closed #{red_b}" in ln for ln in logs)


def test_a_failed_close_is_retried_for_the_red_a_sibling_already_recorded(fx, monkeypatch):
    """A sibling's success record must not mark the sha judged while this red's close did not land."""
    red_a, red_b, _ordinary = _two_reds_one_hotfix(fx)
    real = R.Reporter.say

    def flaky(self, issue, body, close=False):
        if close and int(issue) == red_a and not getattr(flaky, "tripped", False):
            flaky.tripped = True
            return False
        return real(self, issue, body, close=close)

    monkeypatch.setattr(R.Reporter, "say", flaky)
    runs = [{"databaseId": 77, "conclusion": "success", "name": "CI", "status": "completed", "headBranch": "master"}]
    _tick(fx, runs)
    assert fx.state_of(red_a) == "OPEN" and fx.state_of(red_b) == "CLOSED"
    verdict, logs = _tick(fx, runs)
    assert verdict == "idle"  # the ordinary member already landed; the retry is the watch, not a new cycle
    assert fx.state_of(red_a) == "CLOSED" and "run 77" in fx.comments(red_a)
    assert any(f"closed #{red_a}" in ln for ln in logs)


def test_a_skipped_or_cancelled_sibling_run_does_not_hide_a_green_verdict(fx):
    """A completed success plus a skipped or cancelled run is green (ci-watch.sh). It must close."""
    red, _ordinary = _lifted_red(fx, close_on_green=True)
    runs = [
        {"databaseId": 77, "conclusion": "success", "name": "CI", "status": "completed", "headBranch": "master"},
        {"databaseId": 78, "conclusion": "skipped", "name": "deploy", "status": "completed", "headBranch": "master"},
        {"databaseId": 79, "conclusion": "cancelled", "name": "again", "status": "completed", "headBranch": "master"},
    ]
    verdict, logs = _tick(fx, runs)
    assert verdict == "cycle:0:planned" and fx.state_of(red) == "CLOSED"
    assert "run 77" in fx.comments(red) and any(f"closed #{red}" in ln for ln in logs)


def test_a_green_named_job_closes_that_red_while_its_siblings_job_stays_red(fx):
    """Two reds, one sha. The red job re-holds; the green job still closes and does not lift the other."""
    red_unit, red_lint, ordinary = _two_reds_one_hotfix(fx, bodies=("ci-job: unit\n", "ci-job: lint\n"))
    runs = [{"databaseId": 11, "conclusion": "failure", "name": "CI", "status": "completed", "headBranch": "master",
             "jobs": [{"name": "unit", "status": "completed", "conclusion": "failure"},
                      {"name": "lint", "status": "completed", "conclusion": "success"}]}]
    verdict, logs = _tick(fx, runs)
    assert verdict == "idle" and not fx.on_master(0) and fx.state_of(ordinary) == "OPEN"
    assert fx.state_of(red_unit) == "OPEN" and fx.state_of(red_lint) == "CLOSED"
    assert "run 11" in fx.comments(red_lint) and "run 11" not in fx.comments(red_unit)
    assert any("job `unit`" in ln for ln in logs) and any(f"closed #{red_lint}" in ln for ln in logs)


def test_close_on_green_ci_must_be_a_bool(fx):
    fx.train["redHold"] = {"releaseOn": "landed", "closeOnGreenCi": "yes"}
    fx.write_config()
    with pytest.raises(SystemExit, match="closeOnGreenCi"):
        T.load_config(fx.work)
    fx.train["redHold"] = {"releaseOn": "landed"}
    fx.write_config()
    assert T.load_config(fx.work).close_on_green_ci is False


def test_a_retest_that_proves_every_failing_file_red_on_the_base_is_a_red_base_whatever_the_gate_concluded(fx):
    """#7130 (train 253): the gate compared the two runs' named failures, found its own summary lines unequal (a wall
    time), called the red the change's and did not print the RED-BASE line; the per-file retest had said the file
    fails on master alone. The train reads the retest: nobody is returned, the limit stays, the report and the
    project's redBase hook name the files, the ledger's batch row carries cause red-integration."""
    issues = fx.members(3)
    report = fx.member(9)
    fx.train["reportIssue"] = str(report)
    fx.train["hooks"] = {"redBase": 'printf "%s|%s|%s|%s\\n" "$AUTOCODER_TRAIN_BRANCH" "$AUTOCODER_RED_BASE_FILES" "$AUTOCODER_TRAIN_INTEGRATION" "$AUTOCODER_RED_BASE_LINE" >> "$FX_STATE/redbase.log"'}
    fx.write_config()
    (fx.state / "infra.script").write_text("retest-red-base\n")
    code, _ = fx.run()
    assert code == 0 and len(fx.gates()) == 1            # no bisection, no re-gate
    assert fx.dropped() == [] and not any(fx.on_master(i) for i in range(3))
    assert [fx.state_of(i) for i in issues] == ["OPEN"] * 3
    assert all("returned:" not in fx.comments(i) for i in issues)
    st = R.State(fx.rc())
    assert st.limit() == 8 and st.batch()["history"][-1]["verdict"] == "red-base"
    note = fx.comments(report)
    assert "red `master`, not a member's" in note and "red base: t_shared.test" in note
    hook = (fx.state / "redbase.log").read_text().splitlines()
    assert len(hook) == 1 and hook[0].startswith("train/") and "|t_shared.test|master|red base: t_shared.test" in hook[0]
    rows = (fx.state / "timings.log").read_text()
    assert "--verdict red --cause red-integration" in rows


def test_a_retest_with_one_file_still_the_changes_is_the_changes_red_and_is_attributed_as_before(fx):
    issues = fx.members(1)
    (fx.state / "infra.script").write_text("retest-mixed\n")
    code, _ = fx.run()
    assert code == 0
    assert [d[0] for d in fx.dropped()] == [str(issues[0])] and "returned:" in fx.comments(issues[0])
    assert R.State(fx.rc()).batch()["history"][-1]["verdict"] == "red"


def test_retest_red_base_reads_only_a_unanimous_retest():
    red = "   a.test: fails on origin/master too (red base, not this change's)\n"
    own = "   b.test: passes on origin/master (this change's)\n"
    unnamed = "   c.test: not named on origin/master, whose run failed without naming a test file\n"
    assert R.retest_red_base(red + red) == ["a.test"]
    assert R.retest_red_base(red + own) == [] and R.retest_red_base(red + unnamed) == [] and R.retest_red_base("::error::x\n") == []
    assert R.red_base_files(red + "merge-to-integration: RED-BASE -- origin/master (c44669ae) fails alone too with the same 2 named failure(s) in a.test d.test: red master, not this change's.\n") == ["a.test", "d.test"]


def test_a_landing_on_a_red_base_publishes_and_says_the_red_is_the_integration_branchs(fx):
    issues = fx.members(3)
    report = fx.member(9)
    fx.train["reportIssue"] = str(report)
    fx.write_config()
    (fx.state / "infra.script").write_text("land-red-base\n")
    code, _ = fx.run()
    assert code == 0 and len(fx.gates()) == 1
    assert all(fx.on_master(i) for i in range(3)) and [fx.state_of(i) for i in issues] == ["CLOSED"] * 3
    note = fx.comments(report)
    assert "landed on a RED `master`" in note and "RED-BASE -- origin/master" in note and "not this train's" in note


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
    # an attribute hook that names nobody does not stop the path scan: the text still names a member (#391)
    cyc.rc.hooks["attribute"] = "cat >/dev/null; exit 0"
    assert cyc.named_members(base, members, "AssertionError: files/m1.txt: expected a to equal b") == [members[1]]
    # a hook that names a member is believed as before
    cyc.rc.hooks["attribute"] = "cat >/dev/null; echo " + members[0]["issue"]
    assert cyc.named_members(base, members, "::error::tests: files/m1.txt differs") == [members[0]]
    del cyc.rc.hooks["attribute"]


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
    issues = fx.members(6)
    fx.train.update(batchStart=3)
    fx.write_config()
    fx.run()
    assert [len(g) for g in fx.gates()] == [3]
    dropped = {row["issue"]: row["detail"] for row in events_of("plan-dropped")}
    assert set(dropped) == set(issues[3:])
    assert {(d["state"], d["reason"]) for d in dropped.values()} == {("skip", "batch limit (3) reached")}


def test_planner_fault_records_provisional_and_unjudged_candidates(fx, monkeypatch):
    issues = fx.members(2)

    def partial_plan(cfg, rows, limit, on_candidate):
        row = rows[0]
        return [f"train\t{row['issue']}\t{row['branch']}\t{row['tip']}\tprovisional"], "test fault"

    monkeypatch.setattr(T, "plan_train", partial_plan)
    code, _ = fx.run()
    assert code == 2 and fx.gates() == []
    dropped = {row["issue"]: row["detail"] for row in events_of("plan-dropped")}
    assert set(dropped) == set(issues)
    assert {(d["state"], d["reason"]) for d in dropped.values()} == {("skip", "planner stopped: test fault")}


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


def test_the_regeneration_runs_once_on_the_assembled_tree_and_a_post_merge_hook_never_per_candidate(fx):
    """The planner's probes and the assembly's merges run hooks off: a repository post-merge hook that
    regenerates the tree would otherwise run per candidate (27 minutes of planning for a size-6 train,
    measured); the project's regeneration runs ONCE, on the assembled tree."""
    fx.members(3)
    hooks = fx.root / "hooks"
    hooks.mkdir()
    (hooks / "post-merge").write_text('#!/bin/bash\necho hook >> "$FX_STATE/marker"\n')
    (hooks / "post-merge").chmod(0o755)
    sh("git", "config", "core.hooksPath", str(hooks), cwd=fx.work)
    fx.train["hooks"] = {"regenerate": 'echo regen >> "$FX_STATE/marker"'}
    fx.write_config()
    code, _ = fx.run()
    assert code == 0 and all(fx.on_master(i) for i in range(3))
    assert (fx.state / "marker").read_text().split() == ["regen"]


def test_a_failing_regeneration_blames_nobody_and_gates_nothing(fx):
    issues = fx.members(2)
    fx.train["hooks"] = {"regenerate": "echo 'generator exploded'; exit 3"}
    fx.write_config()
    code, _ = fx.run()
    assert code == 0 and fx.gates() == [] and fx.dropped() == []
    assert [fx.state_of(i) for i in issues] == ["OPEN", "OPEN"]


def test_the_assembly_s_chain_merges_carry_the_train_switch_for_merge_drivers(fx):
    """#364: the assembly's merges are chain merges too; a regenerate driver keeps ours under the switch and
    the regenerate hook rewrites the assembled tree once."""
    marker = fx.root / "driver-env"
    probe = fx.root / "probe.sh"
    probe.write_text(f"#!/bin/sh\necho \"${{AUTOCODER_TRAIN_MERGE:-unset}} ${{AUTOCODER_TRAIN_PHASE:-unset}}\" >> '{marker}'\nexit 0\n")
    probe.chmod(0o755)
    sh("git", "config", "merge.probe.driver", f"sh {probe} %O %A %B %P", cwd=fx.work)
    sh("git", "checkout", "-q", "-B", "master", "origin/master", cwd=fx.work)
    (fx.work / "gen.txt").write_text("base\n")
    (fx.work / ".gitattributes").write_text("gen.txt merge=probe\n")
    sh("git", "add", "-A", cwd=fx.work)
    sh("git", "commit", "-q", "-m", "a generated file under the probe driver", cwd=fx.work)
    sh("git", "push", "-q", "origin", "master", cwd=fx.work)
    sh("git", "fetch", "-q", "origin", cwd=fx.work)
    issues = []
    for n in range(2):
        name = f"feature/m{n}"
        sh("git", "checkout", "-q", "-B", name, "origin/master", cwd=fx.work)
        (fx.work / "gen.txt").write_text(f"changed by m{n}\n")
        (fx.work / "files").mkdir(exist_ok=True)
        (fx.work / f"files/m{n}.txt").write_text(f"{n}\n")
        sh("git", "add", "-A", cwd=fx.work)
        sh("git", "commit", "-q", "-m", f"work {n}", cwd=fx.work)
        sh("git", "push", "-q", "-f", "origin", name, cwd=fx.work)
        sh("git", "checkout", "-q", "master", cwd=fx.work)
        r = sh(sys.executable, str(ISSUES_FILE), "create", "--title", f"m{n}", "--body", "", "--label", "ready-for-review", cwd=fx.work)
        issues.append(json.loads(r.stdout)["number"])
        sh(sys.executable, str(ISSUES_FILE), "comment", str(issues[-1]), "--body", f"READY on `{name}`", cwd=fx.work)
    marker.unlink(missing_ok=True)
    fx.train["hooks"] = {"regenerate": "printf 'regenerated on the assembled tree\\n' > gen.txt"}
    fx.write_config()
    code, _ = fx.run()
    assert code == 0 and len(fx.gates()) == 1
    seen = set(filter(None, marker.read_text().split("\n")))
    assert "1 assemble" in seen, seen                      # m1's merge after m0 conflicted in gen.txt at assembly
    assert seen <= {"1 plan", "1 assemble"}, seen          # every train merge carried the switch; no developer merge ran the driver
    assert sh("git", "show", "origin/master:gen.txt", cwd=fx.work).stdout == "regenerated on the assembled tree\n"
    assert [fx.state_of(i) for i in issues] == ["CLOSED", "CLOSED"]


def test_a_regeneration_that_fails_on_one_member_alone_returns_that_member_and_the_next_cycle_trains_the_rest(fx):
    """#364: the per-candidate generation that used to find a `generator-failed` member on every plan is
    gone, so a failed assembled regeneration that names no path is attributed once, by trying each member
    alone; the member whose tree fails alone is returned, the rest train next cycle."""
    issues = fx.members(3)
    fx.train["hooks"] = {"regenerate": "if [ -f files/m1.txt ]; then echo 'generator exploded'; exit 3; fi; true"}
    fx.write_config()
    code, cyc = fx.run()
    assert code == 0 and fx.gates() == []
    assert [str(i) for i in cyc.returned_total] == [str(issues[1])]
    assert [d[0] for d in fx.dropped()] == [str(issues[1])]
    assert "fails on this member's tree alone" in fx.comments(issues[1])
    assert [fx.state_of(i) for i in issues] == ["OPEN"] * 3
    code, _ = fx.run()
    assert code == 0 and len(fx.gates()) == 1
    assert fx.on_master(0) and fx.on_master(2) and not fx.on_master(1)
    assert [fx.state_of(i) for i in issues] == ["CLOSED", "OPEN", "CLOSED"]


def test_a_regeneration_every_member_fails_alone_blames_nobody(fx):
    """Every member failing alone is the regeneration's own failure (as a path every member touches names
    nobody): no member is returned."""
    issues = fx.members(2)
    fx.train["hooks"] = {"regenerate": "echo 'generator exploded'; exit 3"}
    fx.write_config()
    code, cyc = fx.run()
    assert code == 0 and fx.gates() == [] and fx.dropped() == [] and cyc.returned_total == []
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
    # every landed row names the landed commit (the landing report looks the CI verdict up by it)
    assert all(re.search(r"--event landed --batch \S+ --sha [0-9a-f]{40}$", r) for r in rows if "--event landed" in r)
    # the verdict row carries the assembly and gate seconds; a green batch gets a second row with the publish
    # seconds once the close-out is done (the report merges the rows of one id)
    batch = [r for r in rows if r.startswith("batch ")]
    assert len(batch) == 2 and all("--verdict green" in r and "--members" in r for r in batch)
    assert "--assembly-s" in batch[0] and "--gate-s" in batch[0] and "--publish-s" in batch[1]
    assert re.search(r"--assembly-s \d+ --gate-s \d+", batch[0]) and re.search(r"--publish-s \d+ --verdict green$", batch[1])
    plan = [r for r in rows if r.startswith("plan --issue")]
    assert len(plan) == 3 and all("--verdict train --seconds" in r for r in plan)
    # every READY reached the ledger once, stamped with the comment's own time (the file backend keeps minutes)
    ready = [r for r in rows if r.startswith("change --issue") and "--event ready" in r]
    assert len(ready) == 3 and all(re.search(r"--event ready --ts \d{4}-\d\d-\d\dT\d\d:\d\d:00Z$", r) for r in ready)
    fx.run()   # a second cycle sees the same READYs (closed issues are not listed) and writes no second row
    rows2 = (fx.state / "timings.log").read_text().splitlines()
    assert sum(r.startswith("change --issue") and "--event ready" in r for r in rows2) == 3


def test_every_ledger_row_and_the_gate_learn_the_repository_id(fx):
    fx.members(2)
    fx.run()
    rid = T.repo_id(fx.rc().cfg)
    assert rid and re.fullmatch(r"work-[0-9a-f]{8}", rid)
    assert set((fx.state / "timings-repo.log").read_text().split()) == {rid}
    assert set((fx.state / "gate-repo.log").read_text().split()) == {rid}


def test_a_gate_ended_by_a_signal_is_infra_and_the_train_records_the_gate_end_it_could_not(fx):
    issues = fx.members(3)
    (fx.state / "infra.script").write_text("killed\n")
    fx.run()
    assert len(fx.gates()) == 2 and fx.gates()[0] == fx.gates()[1]     # re-gated once, the same set
    assert fx.dropped() == [] and [fx.state_of(i) for i in issues] == ["CLOSED"] * 3
    rows = [ln.split() for ln in (fx.state / "timings.log").read_text().splitlines()]
    verdicts = [(r[r.index("--verdict") + 1], r[r.index("--cause") + 1] if "--cause" in r else "") for r in rows if r[:1] == ["batch"] and "--verdict" in r]
    assert verdicts[0] == ("infra", "infra") and ("green", "") in verdicts
    events = [json.loads(ln) for ln in Path(os.environ["AUTOCODER_ISSUE_EVENTS"]).read_text().splitlines()]
    ends = [e for e in events if e["event"] == "gate-end"]
    assert len(ends) == 1 and ends[0]["issue"] == 0 and ends[0]["detail"]["outcome"] == "aborted"
    assert ends[0]["branch"].startswith("train/") and "signal" in ends[0]["detail"]["reason"] and ends[0]["detail"]["duration_s"] >= 0


def test_a_gate_that_recorded_its_own_end_gets_no_second_gate_end_from_the_train(fx):
    fx.members(2)
    (fx.state / "infra.script").write_text("infra\n")
    fx.run()
    events = [json.loads(ln) for ln in Path(os.environ["AUTOCODER_ISSUE_EVENTS"]).read_text().splitlines()]
    assert [e["detail"]["outcome"] for e in events if e["event"] == "gate-end"] == ["escalated"]


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
    assert rows[0].startswith("batch-begin --pid") and rows[-2].startswith("batch-end --force")
    assert rows[-1] == "drain --branch master"                     # the fast lane lands right behind the batch
    assert len(fx.gates()) == 1                                    # the cycle itself pushes nothing to the integration branch


def test_the_fast_lane_is_drained_between_gate_passes_not_only_at_the_cycle_end(fx, tmp_path, monkeypatch):
    # a red set bisects over several passes; a documents-only commit must not wait for the whole cycle (#379)
    stub = tmp_path / "publisher.sh"
    stub.write_text('#!/bin/bash\necho "$1 $2 $3" >> "$FX_STATE/publisher.log"\n')
    monkeypatch.setenv("AUTOCODER_TRAIN_PUBLISHER", str(stub))
    fx.members(4, bad={3})
    fx.run()
    rows = (fx.state / "publisher.log").read_text().splitlines()
    drains = [i for i, r in enumerate(rows) if r == "drain --branch master"]
    # four members, the last bad: the set is red (a drain follows that pass), the first half lands, the second
    # half's first member lands alone and the bad one is red by inference (no gate): one pass that did not
    # land, followed by a drain, plus the cycle's own drain at the end
    assert len(fx.gates()) == 3
    assert len(drains) == 2
    assert drains[0] < rows.index(next(r for r in rows if r.startswith("batch-end")))   # the first drain came before the batch ended


def test_the_daemon_runs_the_project_tick_command_at_most_once_per_interval(fx):
    marker = fx.state / "tick-cmd.log"
    fx.train["tickCmd"] = f"echo ran >> {marker}"
    fx.train["tickCmdEverySeconds"] = 3600
    fx.write_config()
    d = R.Daemon(fx.rc(), log=lambda m: None, interval=1, max_ticks=3, sleep=lambda s: None)
    assert d.loop() == 0
    assert marker.read_text().splitlines() == ["ran"]              # three ticks, one run inside the interval
    fx.train["tickCmdEverySeconds"] = 0
    fx.write_config()
    d = R.Daemon(fx.rc(), log=lambda m: None, interval=1, max_ticks=2, sleep=lambda s: None)
    assert d.loop() == 0
    assert marker.read_text().splitlines() == ["ran", "ran", "ran"]   # every tick when the interval is 0


def test_a_failing_or_slow_tick_command_never_ends_the_tick(fx):
    logged = []
    fx.train["tickCmd"] = "echo boom >&2; exit 7"
    fx.train["tickCmdEverySeconds"] = 0
    fx.write_config()
    d = R.Daemon(fx.rc(), log=logged.append, interval=1, max_ticks=1, sleep=lambda s: None)
    assert d.loop() == 0
    assert any("tick command exited 7" in m and "boom" in m for m in logged)
    assert json.loads((fx.rc().cfg.state_dir / "daemon.json").read_text())["verdict"] == "idle"
    fx.train["tickCmd"] = "sleep 5"
    fx.train["tickCmdTimeoutSeconds"] = 1
    fx.write_config()
    logged.clear()
    d = R.Daemon(fx.rc(), log=logged.append, interval=1, max_ticks=1, sleep=lambda s: None)
    assert d.loop() == 0
    assert any("tick command killed after 1s" in m for m in logged)


# ── an empty landing is terminal: nothing to land, nobody bisected ──────────────────────
def gen_member(fx, n, paths):
    """A READY issue whose branch changes only <paths> (generated files on master)."""
    name = f"feature/g{n}"
    sh("git", "checkout", "-q", "-B", name, "origin/master", cwd=fx.work)
    for p in paths:
        (fx.work / p).write_text(f"edited by g{n}\n")
    sh("git", "add", "-A", cwd=fx.work)
    sh("git", "commit", "-q", "-m", f"gen work {n}", cwd=fx.work)
    sh("git", "push", "-q", "-f", "origin", name, cwd=fx.work)
    sh("git", "checkout", "-q", "master", cwd=fx.work)
    r = sh(sys.executable, str(ISSUES_FILE), "create", "--title", f"g{n}", "--body", "", "--label", "ready-for-review", cwd=fx.work)
    issue = json.loads(r.stdout)["number"]
    sh(sys.executable, str(ISSUES_FILE), "comment", str(issue), "--body", f"READY on `{name}`", cwd=fx.work)
    return issue


def generated_on_master(fx, attrs=True):
    """gen/a.txt and gen/b.txt on master, merged by the `regen` driver when <attrs>, and a regenerate hook
    that puts them back from the base (what a project's regeneration does to a hand edit of a generated file)."""
    sh("git", "checkout", "-q", "-B", "master", "origin/master", cwd=fx.work)
    (fx.work / "gen").mkdir(exist_ok=True)
    (fx.work / "gen/a.txt").write_text("generated\n")
    (fx.work / "gen/b.txt").write_text("generated\n")
    if attrs:
        (fx.work / ".gitattributes").write_text("gen/* merge=regen\n")
    sh("git", "add", "-A", cwd=fx.work)
    sh("git", "commit", "-q", "-m", "generated files", cwd=fx.work)
    sh("git", "push", "-q", "origin", "master", cwd=fx.work)
    sh("git", "fetch", "-q", "origin", cwd=fx.work)
    hook = fx.root / "regen.sh"
    hook.write_text("#!/bin/bash\ngit checkout -q \"$AUTOCODER_TRAIN_BASE\" -- gen/\n")
    fx.train["hooks"] = {**fx.train.get("hooks", {}), "regenerate": f"bash {hook}"}
    fx.write_config()


def test_an_empty_rebase_ends_the_train_as_nothing_to_land_without_a_bisect(fx):
    generated_on_master(fx, attrs=False)          # not classified at the queue: the gate is where it shows
    issues = [gen_member(fx, 0, ["gen/a.txt"]), gen_member(fx, 1, ["gen/b.txt"])]
    code, cyc = fx.run()
    assert code == 0
    assert len(fx.gates()) == 1 and fx.gates()[0] == []          # one gate, of a tree with no change; never a second
    assert [fx.state_of(i) for i in issues] == ["OPEN"] * 2       # nothing closed
    assert all("landed nothing (regenerate-only or already on the integration branch)" in fx.comments(i) for i in issues)
    assert all("not bisected" in fx.comments(i) for i in issues)
    assert sorted(d[0] for d in fx.dropped()) == sorted(str(i) for i in issues)
    assert all(d[3].startswith("landed nothing") for d in fx.dropped())
    assert R.State(fx.rc()).limit() == 8                           # an empty landing says nothing about the batch size
    assert cyc.returned_total == [] and cyc.landed_total == []
    rows = [ln.split() for ln in (fx.state / "timings.log").read_text().splitlines()]
    assert any(r[:1] == ["batch"] and "aborted" in r and "other" in r for r in rows)
    # the queue never offers these tips again: a train dropped them
    q = {r["issue"]: r for r in T.plan_queue(fx.rc().cfg)}
    assert {q[i]["state"] for i in issues} == {"train-dropped"}
    # and a second cycle plans nothing and gates nothing
    fx.run()
    assert len(fx.gates()) == 1


def test_an_empty_half_in_a_bisection_puts_the_other_half_red_by_inference(fx):
    generated_on_master(fx, attrs=False)
    g = [gen_member(fx, 0, ["gen/a.txt"]), gen_member(fx, 1, ["gen/b.txt"])]
    bad = fx.member(2, bad=True)
    fx.run()
    gates = fx.gates()
    assert gates[0] and gates[1] == []                             # the set is red; the first half (the two gen members) is empty
    assert fx.state_of(bad) == "OPEN" and "returned" in fx.comments(bad)
    assert {d[0]: d[3].split(" (")[0].split(" with")[0] for d in fx.dropped()} == {str(g[0]): "landed nothing", str(g[1]): "landed nothing", str(bad): "the gate failed"}
    assert len(gates) == 2                                         # the bad member alone is red by inference, no third gate


def test_a_regenerate_only_item_is_told_once_per_tip_and_never_planned(fx):
    fx.train["regeneratedMergeDrivers"] = ["regen"]
    fx.train["regeneratedAdvice"] = "Change the source and regenerate."
    generated_on_master(fx)
    gen = gen_member(fx, 0, ["gen/a.txt"])
    ok = fx.member(1)
    code, _ = fx.run()
    assert code == 0 and len(fx.gates()) == 1 and fx.gates()[0] == ["files/m1.txt"]   # the gen member is not in the train
    assert fx.on_master(1) and fx.state_of(ok) == "CLOSED" and fx.state_of(gen) == "OPEN"
    told = fx.comments(gen)
    assert told.count("regenerate-only") == 1 and "`gen/a.txt`" in told and "Change the source and regenerate." in told
    fx.run()                                                       # a second cycle: no second comment, still not planned
    assert fx.comments(gen).count("regenerate-only") == 1 and len(fx.gates()) == 1
    assert fx.dropped() == []                                      # never trained, so never dropped: the queue state keeps it out
    q = {r["issue"]: r for r in T.plan_queue(fx.rc().cfg)}
    assert q[gen]["state"] == "regenerate-only"


# ── the READY's named sha and the branch's current tip (readyTip, train_lib.followed_tip) ──
def named_member(fx, n, body_extra=""):
    """fx.member(n), but the READY names the branch's tip as enqueue.sh and a prebank block do."""
    issue = fx.member(n)
    tip = T.git(fx.work, "rev-parse", "--short=10", f"origin/feature/m{n}").stdout.strip()
    sh(sys.executable, str(ISSUES_FILE), "comment", str(issue), "--body", f"READY `feature/m{n}` @ {tip}{body_extra}", cwd=fx.work)
    return issue, tip


def land_sibling(fx, path="README.md", text="sibling\n"):
    sh("git", "checkout", "-q", "-B", "master", "origin/master", cwd=fx.work)
    (fx.work / path).parent.mkdir(parents=True, exist_ok=True)
    (fx.work / path).write_text(text)
    sh("git", "add", "-A", cwd=fx.work)
    sh("git", "commit", "-q", "-m", "sibling", cwd=fx.work)
    sh("git", "push", "-q", "origin", "master", cwd=fx.work)
    sh("git", "fetch", "-q", "origin", cwd=fx.work)


def rebase_member(fx, n):
    name = f"feature/m{n}"
    sh("git", "checkout", "-q", "-B", name, f"origin/{name}", cwd=fx.work)
    sh("git", "rebase", "-q", "origin/master", cwd=fx.work)
    sh("git", "push", "-q", "-f", "origin", name, cwd=fx.work)
    sh("git", "checkout", "-q", "master", cwd=fx.work)
    sh("git", "fetch", "-q", "origin", cwd=fx.work)
    return T.git(fx.work, "rev-parse", "--short=10", f"origin/{name}").stdout.strip()


def test_a_rebased_tip_with_the_readys_patches_is_trained_and_the_issue_is_told_once(fx):
    issue, old = named_member(fx, 0)
    land_sibling(fx)
    new = rebase_member(fx, 0)
    code, cyc = fx.run()
    assert code == 0 and fx.on_master(0) and fx.state_of(issue) == "CLOSED"
    assert [m["tip"][:10] for m in cyc.record["members"]] == [new]
    told = fx.comments(issue)
    assert told.count(f"READY named `{old}`, taking the rebased tip `{new}`: same patches") == 1
    assert "No new READY is needed for a rebase or fast-forward of the same work." in told
    assert (fx.rc().cfg.state_dir / "followed-tip.tsv").read_text().startswith(f"{issue}\t{new}\t")


def test_a_tip_with_other_work_is_told_tip_moved_once_and_never_trained_until_a_ready_names_it(fx):
    moved, old = named_member(fx, 0)
    ok = fx.member(1)
    sh("git", "checkout", "-q", "-B", "feature/m0", "origin/feature/m0", cwd=fx.work)
    (fx.work / "files/m0.txt").write_text("fixed\n")
    sh("git", "commit", "-q", "-am", "an unbanked fix", cwd=fx.work)
    sh("git", "push", "-q", "origin", "feature/m0", cwd=fx.work)
    sh("git", "checkout", "-q", "master", cwd=fx.work)
    new = T.git(fx.work, "rev-parse", "--short=10", "origin/feature/m0").stdout.strip()
    code, _ = fx.run()
    assert code == 0 and len(fx.gates()) == 1 and fx.gates()[0] == ["files/m1.txt"]    # m0 is not in the train
    assert fx.state_of(ok) == "CLOSED" and fx.state_of(moved) == "OPEN" and not fx.on_master(0)
    told = fx.comments(moved)
    assert told.count("`tip-moved`") == 1 and f"carries work the READY at `{old}` did not name" in told and "re-post READY at this tip" in told
    fx.run()                                                       # a second cycle: no second comment, still not planned
    assert fx.comments(moved).count("`tip-moved`") == 1 and len(fx.gates()) == 1 and fx.dropped() == []
    sh(sys.executable, str(ISSUES_FILE), "comment", str(moved), "--body", f"READY `feature/m0` @ {new} (banked)", cwd=fx.work)
    code, _ = fx.run()
    assert code == 0 and fx.on_master(0) and fx.state_of(moved) == "CLOSED"
    assert T.git(fx.work, "cat-file", "-p", "origin/master:files/m0.txt").stdout == "fixed\n"   # the banked tip, not the READY's


def test_a_tip_that_conflicts_with_the_integration_branch_is_told_once_and_planned_at_its_rebased_tip(fx):
    """The queue's merge-tree prefilter holds a branch that conflicts with the integration branch out of the plan
    as `conflict`; before this the owner learned nothing (only an assembly-time conflict was returned with a comment),
    so the branch sat in the queue until a person noticed. Now the cycle tells the issue once per tip, and a
    rebased tip is judged afresh."""
    issue, old = named_member(fx, 0)
    ok = fx.member(1)
    land_sibling(fx, path="files/m0.txt", text="master wrote this first\n")   # the sibling took m0's file
    code, _ = fx.run()
    assert code == 0 and len(fx.gates()) == 1 and fx.gates()[0] == ["files/m1.txt"]    # m0 is not in the train
    assert fx.state_of(ok) == "CLOSED" and fx.state_of(issue) == "OPEN"
    assert T.git(fx.work, "cat-file", "-p", "origin/master:files/m0.txt").stdout != "0\n"   # m0's content never landed
    told = fx.comments(issue)
    assert told.count("`conflict`") == 1 and "files/m0.txt" in told and f"`{old}`" in told and "Rebase onto" in told
    fx.run()                                                       # a second cycle: no second comment, still not planned
    assert fx.comments(issue).count("`conflict`") == 1 and len(fx.gates()) == 1 and fx.dropped() == []
    sh("git", "checkout", "-q", "-B", "feature/m0", "origin/master", cwd=fx.work)   # the owner's rebase: m0 resolved over master
    (fx.work / "files/m0.txt").write_text("master wrote this first\n0\n")
    sh("git", "commit", "-q", "-am", "work 0, rebased over the sibling", cwd=fx.work)
    sh("git", "push", "-q", "-f", "origin", "feature/m0", cwd=fx.work)
    sh("git", "checkout", "-q", "master", cwd=fx.work)
    new = T.git(fx.work, "rev-parse", "--short=10", "origin/feature/m0").stdout.strip()
    sh(sys.executable, str(ISSUES_FILE), "comment", str(issue), "--body", f"READY `feature/m0` @ {new} (rebased)", cwd=fx.work)
    code, _ = fx.run()
    assert code == 0 and fx.state_of(issue) == "CLOSED" and fx.comments(issue).count("`conflict`") == 1


def test_the_plan_reads_a_tip_pushed_while_the_preflight_ran(fx):
    """The cycle fetches once when it opens, then runs the project's preflight, which can take minutes. A
    push in that window (the worker's rebase after a sibling landed) must be the tip the plan classifies,
    so the plan fetches again right before it: here the preflight hook pushes the rebase and leaves the planning
    clone's tracking ref at the old tip, as a push from another clone would (without the second fetch the plan
    takes the old tip and the landed tree lacks the sibling's base)."""
    issue, old = named_member(fx, 0)
    land_sibling(fx)
    hook = fx.root / "preflight-pushes-a-rebase.sh"
    hook.write_text(f"""#!/bin/bash
set -e
cd "{fx.work}"
old=$(git rev-parse origin/feature/m0)
git checkout -q -B feature/m0 origin/feature/m0 && git rebase -q origin/master && git push -q -f origin feature/m0
git rev-parse --short=10 HEAD > "{fx.state}/pushed-tip"
git checkout -q master
git update-ref refs/remotes/origin/feature/m0 "$old"   # as a push from another clone leaves this one: stale until it fetches
""")
    fx.train["hooks"] = {"preflight": f"bash {hook}"}
    fx.write_config()
    fetched_before = T.git(fx.work, "rev-parse", "--short=10", "origin/feature/m0").stdout.strip()
    assert fetched_before == old                                   # the clone still holds the old tip when the cycle opens
    code, cyc = fx.run()
    new = (fx.state / "pushed-tip").read_text().strip()         # the branch is deleted once landed, so read the hook's record
    assert new != old and code == 0
    assert [m["tip"][:10] for m in cyc.record["members"]] == [new]     # the plan took the rebased tip, not the one fetched at open
    assert fx.on_master(0) and fx.state_of(issue) == "CLOSED"
    assert f"taking the rebased tip `{new}`" in fx.comments(issue)


# ── a READY's branch must belong to the issue (train_lib.branch_owned) ───────────────────────
def test_a_cycle_tells_a_foreign_branch_once_per_tip_and_plans_a_declared_stack(tmp_path):
    """With `branchOwnership: issue` (the default) the fixture's `feature/m<n>` branches belong to nobody: the
    cycle tells each such item once, plans none of them, and a READY whose `stack:` line declares the branch
    for the issue is planned like any other."""
    fx = Fx(tmp_path, {"branchOwnership": "issue"})
    foreign = fx.member(0)
    declared = fx.member(1)
    sh(sys.executable, str(ISSUES_FILE), "comment", str(declared), "--body",
       f"READY `feature/m1` @ {T.git(fx.work, 'rev-parse', '--short=10', 'origin/feature/m1').stdout.strip()}\nstack: `feature/m1` carries #{declared}", cwd=fx.work)
    code, _ = fx.run()
    assert code == 0 and len(fx.gates()) == 1 and fx.gates()[0] == ["files/m1.txt"]   # m0 is not in the train
    assert fx.state_of(declared) == "CLOSED" and fx.state_of(foreign) == "OPEN" and not fx.on_master(0)
    told = fx.comments(foreign)
    assert told.count("`foreign-branch`") == 1 and f"`feature/m0` does not belong to #{foreign}" in told and f"stack: `feature/m0` carries #{foreign}" in told
    fx.run()   # a second cycle: no second comment, still not planned
    assert fx.comments(foreign).count("`foreign-branch`") == 1 and len(fx.gates()) == 1 and fx.dropped() == []


def test_a_resumed_close_out_names_no_commit_in_its_landed_row(fx):
    # The process died after member 0 landed; another landing moved the integration branch before the resume, so the
    # branch's tip is not the commit member 0 landed in. The ledger row names no commit rather than the wrong one.
    issues = fx.members(2)
    tips = [T.git(fx.work, "rev-parse", f"origin/feature/m{i}").stdout.strip() for i in range(2)]
    sh("git", "push", "-q", "origin", f"{tips[0]}:refs/heads/master", cwd=fx.work)
    sh("git", "checkout", "-q", "--detach", tips[0], cwd=fx.work)
    (fx.work / "later.txt").write_text("x")
    sh("git", "add", "later.txt", cwd=fx.work)
    sh("git", "-c", "user.name=t", "-c", "user.email=t@e.x", "commit", "-q", "-m", "#999: a later landing", cwd=fx.work)
    sh("git", "push", "-q", "origin", "HEAD:refs/heads/master", cwd=fx.work)
    st = R.State(fx.rc())
    st.save_cycle({"started": "then", "members": [{"issue": str(issues[i]), "branch": f"feature/m{i}", "tip": tips[i], "status": "gating", "note": ""} for i in range(2)]})
    sh("git", "fetch", "-q", "origin", cwd=fx.work)
    R.Cycle(fx.rc(), log=lambda m: None).reconcile()
    rows = [ln for ln in (fx.state / "timings.log").read_text().splitlines() if "--event landed" in ln]
    assert len(rows) == 1 and "--sha" not in rows[0]


# ── the daemon: the train launches itself ───────────────────────────────────────────────
def _timings(fx):
    p = fx.state / "timings.log"
    return p.read_text().splitlines() if p.exists() else []


def test_a_cycle_writes_a_launched_row_per_member_when_it_takes_them(fx):
    issues = fx.members(2)
    code, _ = fx.run()
    assert code == 0
    launched = [ln for ln in _timings(fx) if "--event launched" in ln]
    assert sorted(int(ln.split("--issue ")[1].split()[0]) for ln in launched) == sorted(issues)
    assert all(fx.on_master(i) for i in range(2))


def test_the_daemon_launches_a_cycle_when_the_queue_has_a_launchable_item(fx):
    fx.members(2)
    slept = []
    d = R.Daemon(fx.rc(), log=lambda m: None, interval=7, once=True, sleep=slept.append)
    assert d.loop() == 0
    assert all(fx.on_master(i) for i in range(2))
    assert len(fx.gates()) == 1
    assert [ln for ln in _timings(fx) if "--event launched" in ln]
    rec = json.loads((fx.rc().cfg.state_dir / "daemon.json").read_text())
    assert rec["verdict"] == "cycle:0" and rec["note"] == "planned"
    assert slept == []   # --once: no sleep after the tick


def test_the_daemon_idles_and_sleeps_when_nothing_is_launchable(fx):
    slept = []
    d = R.Daemon(fx.rc(), log=lambda m: None, interval=7, max_ticks=2, sleep=slept.append)
    assert d.loop() == 0
    assert fx.gates() == []
    assert slept == [7]   # a sleep between the two ticks, none after the last
    assert json.loads((fx.rc().cfg.state_dir / "daemon.json").read_text())["verdict"] == "idle"


def test_the_daemon_waits_while_a_train_holds_the_lease(fx):
    fx.members(1)
    held = R.Lease(R.State(fx.rc()))
    ok, _ = held.acquire()
    assert ok
    try:
        d = R.Daemon(fx.rc(), log=lambda m: None, interval=0, once=True)
        assert d.tick() == "train-live"
    finally:
        held.release()
    assert fx.gates() == []
    assert not fx.on_master(0)
    # the lease released, the next tick launches
    assert R.Daemon(fx.rc(), log=lambda m: None, interval=0, once=True).tick() == "cycle:0:planned"
    assert fx.on_master(0)


def test_a_pause_file_holds_every_launch_and_says_why_once(fx):
    fx.members(1)
    rc = fx.rc()
    (rc.cfg.state_dir).mkdir(parents=True, exist_ok=True)
    (rc.cfg.state_dir / "daemon.pause").write_text("gate host is being rebooted\n")
    said = []
    d = R.Daemon(rc, log=said.append, interval=0)
    assert d.tick() == "paused"
    assert d.tick() == "paused"
    assert sum("paused (gate host is being rebooted)" in m for m in said) == 1
    assert fx.gates() == []
    (rc.cfg.state_dir / "daemon.pause").unlink()
    assert d.tick() == "cycle:0:planned"
    assert fx.on_master(0)


def test_a_stop_file_ends_the_loop_at_the_next_tick_and_is_consumed(fx):
    fx.members(1)
    rc = fx.rc()
    rc.cfg.state_dir.mkdir(parents=True, exist_ok=True)
    (rc.cfg.state_dir / "daemon.stop").write_text("x\n")
    d = R.Daemon(rc, log=lambda m: None, interval=0)
    assert d.loop() == 0
    assert not (rc.cfg.state_dir / "daemon.stop").exists()
    assert fx.gates() == []   # stopped before launching


def test_a_second_daemon_is_refused_while_the_lock_is_held(fx):
    rc = fx.rc()
    first = R.Daemon(rc, log=lambda m: None)
    ok, _ = first.acquire()
    assert ok
    try:
        said = []
        assert R.Daemon(rc, log=said.append, interval=0, once=True).loop() == 1
        assert any("a daemon already runs" in m and f"pid {os.getpid()}" in m for m in said)
        assert R.Daemon.holder(R.State(rc)).startswith(f"pid {os.getpid()}")
    finally:
        first.release()
    assert R.Daemon.holder(R.State(rc)) == ""


def test_a_cycle_that_planned_nothing_sleeps_before_the_next_tick(fx):
    """Launchable items the planner skips must not spin the daemon: one preflight per interval."""
    fx.members(1)
    slept = []

    class Nothing:
        record = {}

        def run(self, size=None, launchable=None):
            return 0, []
    d = R.Daemon(fx.rc(), log=lambda m: None, interval=9, max_ticks=2, sleep=slept.append, cycle=Nothing)
    assert d.loop() == 0
    assert slept == [9]
    assert json.loads((fx.rc().cfg.state_dir / "daemon.json").read_text())["note"] == "nothing planned"


def test_the_daemon_tells_the_ready_age_of_what_it_launches(fx):
    fx.members(1)
    said = []
    assert R.Daemon(fx.rc(), log=said.append, interval=0, once=True).loop() == 0
    assert any(re.search(r"1 launchable item\(s\): #\d+ \(READY \d+m ago\); launching a cycle", m) for m in said)


def test_the_daemon_survives_a_tick_that_raises_and_ticks_again(fx):
    """A tracker call that times out inside the cycle (a GitHub API i/o timeout in plan_queue) raised through
    tick() and ended the daemon; nothing launched trains until a person noticed. The loop now logs the failure,
    records it as `tick-failed`, sleeps the interval and ticks again."""
    fx.members(1)
    said, slept, runs = [], [], []

    class Boom:
        def __init__(self, *a, **k):
            pass

        def run(self, size=None, launchable=None):
            runs.append(1)
            raise RuntimeError("tracker call `issue_list --state working` exited 3: Post https://api/graphql: i/o timeout")

    d = R.Daemon(fx.rc(), log=said.append, interval=5, max_ticks=2, sleep=slept.append, cycle=Boom)
    assert d.loop() == 0                                             # two ticks, both raising, no traceback out of loop()
    assert len(runs) == 2 and slept == [5]                           # it slept the interval between them, not after the last
    assert sum("tick failed (RuntimeError" in m and "the daemon stays up" in m for m in said) == 2
    rec = json.loads(d.record_path.read_text())
    assert rec["verdict"] == "tick-failed" and rec["note"] == "RuntimeError"


def test_the_cli_runs_a_daemon_tick_and_reports_pauses_stops_and_status(fx):
    fx.members(1)
    cwd = fx.work
    r = sh(sys.executable, str(CLI), "daemon", "--pause", "maintenance", cwd=cwd)
    assert "paused: maintenance" in r.stdout
    r = sh(sys.executable, str(CLI), "daemon", "--once", "--interval", "0", cwd=cwd)
    assert fx.gates() == []
    r = sh(sys.executable, str(CLI), "daemon", "--status", cwd=cwd)
    assert "not running" in r.stdout and "paused: maintenance" in r.stdout and "last tick" in r.stdout and "paused" in r.stdout
    r = sh(sys.executable, str(CLI), "daemon", "--resume", cwd=cwd)
    assert "resumed" in r.stdout
    r = sh(sys.executable, str(CLI), "daemon", "--once", "--interval", "0", cwd=cwd)
    assert r.returncode == 0 and fx.on_master(0)
    r = sh(sys.executable, str(CLI), "daemon", "--stop", cwd=cwd)
    assert "stop requested" in r.stdout
    r = sh(sys.executable, str(CLI), "status", cwd=cwd)
    assert "daemon: not running; stop requested; last tick" in r.stdout


# ── a plan never drops a labelled item silently (every item has a row, the tick's list is compared, a ledger event) ──
def short_read_for(real, issue):
    """A tracker whose `issue_get` of <issue> comes back short: exit 0 and no comment, the shape a read under transport
    pressure can take; every other call is the real tracker's."""
    def fake(cfg, *args, **kw):
        if args[0] == "issue_get" and str(args[1]) == str(issue):
            r = real(cfg, *args, **kw)
            body = json.loads(r.stdout)
            body["comments"], body["body"] = [], ""
            return subprocess.CompletedProcess(args, 0, json.dumps(body), "")
        return real(cfg, *args, **kw)
    return fake


def events_of(kind):
    """The lifecycle ledger's rows of one event kind."""
    p = Path(os.environ["AUTOCODER_ISSUE_EVENTS"])
    rows = [json.loads(ln) for ln in p.read_text().splitlines() if ln.strip()] if p.exists() else []
    return [e for e in rows if e.get("event") == kind]


def test_a_cycle_gives_a_short_read_an_unread_row_logs_the_ticks_differences_and_writes_plan_dropped_events(fx, monkeypatch):
    issues = fx.members(3)
    monkeypatch.setattr(T, "tracker", short_read_for(T.tracker, issues[0]))
    logged = []
    cyc = R.Cycle(fx.rc(), log=logged.append)
    code, _ = cyc.run(launchable=[*issues, 9999])        # the tick listed the three and one the listing no longer returns
    assert code == 0 and len(fx.gates()) == 1
    assert [fx.on_master(i) for i in range(3)] == [False, True, True]   # the two readable members landed; the unread one waits
    assert any(f"plan: #{issues[0]}: unread: issue_get exit 0, 0 comment(s) read; not planned this cycle" in m for m in logged), logged
    assert any("plan: #9999: unlisted: launchable at the tick, absent from the plan's listing (3 listed now, 4 launchable then)" in m for m in logged), logged
    assert any(m.startswith("launchable at the tick but not launchable in this plan: ") and f"#{issues[0]} (unread)" in m and "#9999 (unlisted)" in m for m in logged), logged
    assert any(f"plan skip: #{issues[0]} -: unread: the READY could not be read: issue_get exited 0 with 0 comment(s) read; not planned this cycle" in m for m in logged), logged
    assert any("plan skip: #9999 -: unlisted: launchable at the tick" in m for m in logged), logged
    plan = R.State(fx.rc()).plan()
    assert plan["launchable_at_tick"] == [*issues, 9999] and {s["issue"] for s in plan["skips"]} == {str(issues[0]), "9999"}
    assert {r["issue"]: r["state"] for r in plan["rows"]}[issues[0]] == "unread" and {r["issue"]: r["state"] for r in plan["rows"]}[9999] == "unlisted"
    dropped = {e["issue"]: e["detail"] for e in events_of("plan-dropped")}
    assert dropped[issues[0]]["state"] == "unread" and "issue_get exited 0 with 0 comment(s) read" in dropped[issues[0]]["reason"]
    assert dropped[9999]["state"] == "unlisted" and "absent from the plan's own listing" in dropped[9999]["reason"]
    assert all(event["cycle"] == plan["cycle"] and event["previous_cycle"] is None for event in dropped.values())
    assert set(dropped) == {issues[0], 9999}                        # the planned members are not dropped candidates


def test_an_unread_item_is_planned_by_the_next_cycle_once_its_read_is_whole(fx, monkeypatch):
    issues = fx.members(2)
    real = T.tracker
    monkeypatch.setattr(T, "tracker", short_read_for(real, issues[1]))
    code, _ = fx.run()
    assert code == 0 and fx.on_master(0) and not fx.on_master(1)
    monkeypatch.setattr(T, "tracker", real)
    code, _ = fx.run()
    assert code == 0 and fx.on_master(1)


def test_a_cycle_run_without_a_tick_list_compares_nothing_and_still_records_an_unread_row(fx, monkeypatch):
    issues = fx.members(2)
    monkeypatch.setattr(T, "tracker", short_read_for(T.tracker, issues[0]))
    logged = []
    code, _ = R.Cycle(fx.rc(), log=logged.append).run()
    assert code == 0 and fx.on_master(1) and not fx.on_master(0)
    assert not any(m.startswith("launchable at the tick") for m in logged)
    assert [e["issue"] for e in events_of("plan-dropped")] == [issues[0]]
    assert R.State(fx.rc()).plan()["launchable_at_tick"] is None


def test_a_plan_that_admits_an_item_the_tick_did_not_list_says_so(fx):
    issues = fx.members(2)
    logged = []
    code, _ = R.Cycle(fx.rc(), log=logged.append).run(launchable=[issues[0]])
    assert code == 0
    assert any(m.startswith("launchable in this plan but not at the tick: ") and f"#{issues[1]}" in m for m in logged), logged
    assert events_of("plan-dropped") == []


def test_the_daemon_hands_its_launchable_list_to_the_cycle(fx):
    issues = fx.members(2)
    seen = []

    class Watch:
        record = {}

        def run(self, size=None, launchable=None):
            seen.append(launchable)
            return 0, []
    d = R.Daemon(fx.rc(), log=lambda m: None, interval=1, max_ticks=1, sleep=lambda s: None, cycle=Watch)
    assert d.loop() == 0
    assert seen == [sorted(issues)] or seen == [issues]
