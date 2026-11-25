"""fake-gh.py through the real issues-gh.sh verbs: read-back shapes, label and comment order, loud failure (#403)."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "plugins" / "autocoder" / "scripts"


@pytest.fixture
def gh(tmp_path):
    """A private repo on the GitHub backend with the fake as `gh`; returns a verb runner."""
    bin_dir, repo = tmp_path / "bin", tmp_path / "repo"
    bin_dir.mkdir()
    (bin_dir / "gh").write_text(f'#!/bin/sh\nexec "{sys.executable}" "{SCRIPTS / "fake-gh.py"}" "$@"\n')
    (bin_dir / "gh").chmod(0o755)
    subprocess.run(["git", "init", "-q", "--bare", str(tmp_path / "origin.git")], check=True)
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    subprocess.run(["git", "remote", "add", "origin", str(tmp_path / "origin.git")], cwd=repo, check=True)
    (repo / ".autocoder.json").write_text('{"issueSource": "github"}\n')
    env = {**{k: v for k, v in os.environ.items() if not k.startswith(("AUTOCODER_", "FAKE_GH_"))},
           "PATH": f"{bin_dir}:{os.environ['PATH']}", "ISSUE_SOURCE": "github", "XDG_STATE_HOME": str(tmp_path / "state"),
           "FAKE_GH_STORE": str(tmp_path / "store"), "FAKE_GH_LOG": str(tmp_path / "gh.log")}

    def run(script: str, check: bool = True) -> subprocess.CompletedProcess:
        r = subprocess.run(["bash", "-c", f'source "{SCRIPTS}/issue-fns.sh" && {script}'], cwd=repo, env=env,
                           capture_output=True, text=True)
        assert not check or r.returncode == 0, r.stderr
        return r

    run.log = lambda: [json.loads(x) for x in (tmp_path / "gh.log").read_text().splitlines()]
    run.store = tmp_path / "store"
    return run


def get(gh, n: int) -> dict:
    return json.loads(gh(f"issue_get {n}").stdout)


def numbers(gh, args: str) -> list[int]:
    return [d["number"] for d in json.loads(gh(f"issue_list {args}").stdout)]


def test_create_and_get_have_githubs_shape(gh):
    assert json.loads(gh('issue_create --title "Add a greeting" --body "Print hello." --label P2 --label bug').stdout) \
        == {"number": 1}
    assert get(gh, 1) == {"number": 1, "title": "Add a greeting", "body": "Print hello.", "state": "OPEN",
                          "labels": [{"name": "P2"}, {"name": "bug"}], "comments": []}
    # The store file is the document issue_get prints, so trace-build.py --comments-dir reads it as is.
    assert json.loads((gh.store / "1.json").read_text())["comments"] == []


def test_claim_release_and_the_queues(gh):
    for title in ("one", "two", "three"):
        gh(f'issue_create --title {title} --body b --label P2')
    gh("issue_claim 2")
    assert [x["name"] for x in get(gh, 2)["labels"]] == ["P2", "working"]
    assert numbers(gh, "") == [3, 1]                      # newest first, the claimed one left out
    assert numbers(gh, "--state working") == [2]
    assert numbers(gh, "--state open --limit 1") == [3]
    gh("issue_release 2")
    assert [x["name"] for x in get(gh, 2)["labels"]] == ["P2"]
    assert numbers(gh, "") == [3, 2, 1]
    edits = [e["argv"] for e in gh.log() if e["argv"][:2] == ["issue", "edit"]]
    assert edits == [["issue", "edit", "2", "--add-label", "working"], ["issue", "edit", "2", "--remove-label", "working"]]


def test_label_filter_and_lifecycle_label_order(gh):
    gh('issue_create --title a --body b --label P2 --label bug')
    gh('issue_create --title c --body d --label P3')
    assert numbers(gh, "--label bug") == [1]
    gh("issue_claim 1 && issue_handoff 1 && issue_park 1")
    assert [x["name"] for x in get(gh, 1)["labels"]] == ["P2", "bug", "awaiting-integration"]


def test_comments_keep_server_order_and_wall_clock_created_at(gh):
    gh("issue_create --title a --body b")
    before = datetime.now(timezone.utc).replace(microsecond=0)
    gh('issue_comment 1 --body "first" && issue_comment 1 --body "second"')
    gh('issue_close 1 --comment "closing"')
    doc = get(gh, 1)
    assert [c["body"] for c in doc["comments"]] == ["first", "second", "closing"]
    assert doc["state"] == "CLOSED"
    for c in doc["comments"]:
        t = datetime.strptime(c["createdAt"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        assert 0 <= (t - before).total_seconds() < 30
        assert c["author"] == {"login": "eval"}
    assert numbers(gh, "--state closed") == [1] and numbers(gh, "") == []


def test_concurrent_comments_all_land(gh):
    gh("issue_create --title a --body b")
    gh('for i in 1 2 3 4 5 6 7 8; do issue_comment 1 --body "marker $i" & done; wait')
    assert sorted(c["body"] for c in get(gh, 1)["comments"]) == [f"marker {i}" for i in range(1, 9)]


def test_the_dependency_probe_is_answered(gh):
    # With an origin, issue-deps.sh asks for the repository and its native blockers.
    gh("issue_create --title a --body b")
    assert numbers(gh, "") == [1]
    probes = {e["argv"][0] + " " + e["argv"][1]: e["exit"] for e in gh.log() if e["argv"][0] in ("repo", "api")}
    assert probes == {"repo view": 0, "api graphql": 0}


def test_jq_and_the_text_view(gh):
    gh('issue_create --title a --body b --label P1 && issue_comment 1 --body "hi"')
    assert gh("gh issue view 1 --json labels --jq '.labels[].name'").stdout == "P1\n"
    text = gh("gh issue view 1 --comments").stdout
    assert "title:\ta" in text and text.rstrip().endswith("hi")
    assert gh("gh repo view --json nameWithOwner -q .nameWithOwner").stdout == "example/project\n"


@pytest.mark.parametrize("form, message", [
    ("gh pr list", "fake gh: unsupported form: gh pr list"),
    ("gh issue list --search working", "fake gh: unsupported form"),
    ("gh issue view 1 --json milestone", 'Unknown JSON field: "milestone"'),
    ("gh issue view 7", "Could not resolve to an issue or pull request with the number of 7"),
    ("gh api repos/example/project/issues/1", "fake gh: unsupported form"),
])
def test_an_unknown_form_fails_loudly(gh, form, message):
    gh("issue_create --title a --body b")
    r = gh(form, check=False)
    assert r.returncode == 1 and message in r.stderr and r.stdout == ""
    assert gh.log()[-1] == {"argv": form.split()[1:], "exit": 1}


def test_a_missing_issue_is_a_clean_negative_for_the_backend(gh):
    assert gh("issue_get 9", check=False).returncode == 1
