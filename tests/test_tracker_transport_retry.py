"""train_lib.tracker retries a tracker call that died in transport, a bounded number of times, and
raises at once on any other failure (issue #367)."""
import importlib.util
import os
import stat
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[1] / "plugins" / "autocoder" / "scripts"
spec = importlib.util.spec_from_file_location("train_lib", SCRIPTS / "train_lib.py")
T = importlib.util.module_from_spec(spec)
sys.modules["train_lib"] = T
spec.loader.exec_module(T)


class Cfg:
    def __init__(self, repo):
        self.repo = repo


def fake_issue_fns(tmp_path, failures: int, message: str):
    """An issue-fns.sh whose `issue_get` fails `failures` times with `message` on stderr, then answers."""
    counter = tmp_path / "calls"
    counter.write_text("0")
    script = tmp_path / "issue-fns.sh"
    script.write_text(f"""
issue_get() {{
  n=$(cat "{counter}"); n=$((n + 1)); echo "$n" > "{counter}"
  if [ "$n" -le {failures} ]; then echo '{message}' >&2; exit 1; fi
  echo '{{"number": '"$1"', "state": "open"}}'
}}
""")
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    return script, counter


@pytest.fixture
def repo(tmp_path):
    (tmp_path / "repo").mkdir()
    return tmp_path / "repo"


def test_a_transport_error_is_retried_with_the_configured_pauses(tmp_path, repo, monkeypatch):
    script, counter = fake_issue_fns(tmp_path, 2, 'Post "https://api.github.com/graphql": dial tcp 140.82.113.6:443: i/o timeout')
    monkeypatch.setattr(T, "ISSUE_FNS", script)
    pauses = []
    r = T.tracker(Cfg(repo), "issue_get", "7", sleep=pauses.append)
    assert r.returncode == 0 and '"state": "open"' in r.stdout
    assert pauses == list(T.TRACKER_RETRY_PAUSES[:2])
    assert counter.read_text().strip() == "3"


def test_a_transport_error_that_outlives_every_retry_raises_naming_the_attempts(tmp_path, repo, monkeypatch):
    script, counter = fake_issue_fns(tmp_path, 99, "net/http: TLS handshake timeout")
    monkeypatch.setattr(T, "ISSUE_FNS", script)
    pauses = []
    with pytest.raises(RuntimeError) as e:
        T.tracker(Cfg(repo), "issue_get", "7", sleep=pauses.append)
    assert pauses == list(T.TRACKER_RETRY_PAUSES)
    assert f"after {len(T.TRACKER_RETRY_PAUSES) + 1} attempts" in str(e.value)
    assert counter.read_text().strip() == str(len(T.TRACKER_RETRY_PAUSES) + 1)


def test_any_other_failure_raises_at_once_without_a_pause(tmp_path, repo, monkeypatch):
    script, counter = fake_issue_fns(tmp_path, 99, "GraphQL: Could not resolve to an Issue with the number of 7. (repository.issue)")
    monkeypatch.setattr(T, "ISSUE_FNS", script)
    pauses = []
    with pytest.raises(RuntimeError) as e:
        T.tracker(Cfg(repo), "issue_get", "7", sleep=pauses.append)
    assert pauses == []
    assert "after" not in str(e.value)
    assert counter.read_text().strip() == "1"


def test_check_false_still_retries_transport_but_returns_any_other_failure(tmp_path, repo, monkeypatch):
    script, counter = fake_issue_fns(tmp_path, 1, "dial tcp 140.82.112.6:443: connect: connection refused")
    monkeypatch.setattr(T, "ISSUE_FNS", script)
    pauses = []
    r = T.tracker(Cfg(repo), "issue_get", "7", check=False, sleep=pauses.append)
    assert r.returncode == 0 and pauses == [T.TRACKER_RETRY_PAUSES[0]]
    script2, counter2 = fake_issue_fns(tmp_path / "b", 99, "not found") if (tmp_path / "b").mkdir() is None else (None, None)
    monkeypatch.setattr(T, "ISSUE_FNS", script2)
    pauses = []
    r = T.tracker(Cfg(repo), "issue_get", "7", check=False, sleep=pauses.append)
    assert r.returncode == 1 and pauses == [] and counter2.read_text().strip() == "1"
