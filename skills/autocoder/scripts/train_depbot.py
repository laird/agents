"""train_depbot.py -- the queue's dependency-bot pass (CLI: `merge-train.py depbot`; the daemon's tick runs it).

A dependency-update bot (Dependabot, Renovate) opens pull requests, not issues, and its branches carry no
issue number. The queue reads issues, so without this pass a bot PR is nobody's item: measured on one
project, five bot PRs waited six days, and once a script filed tracking issues by hand their READYs
lacked the `stack:` line the planner needs for a branch that belongs to no issue by name, so three of
them read `foreign-branch` for six hours until a person re-posted the READY. The policy on that project
is that a bot PR lands the same day.

What a pass does, for every open PR by a configured bot author (`train.depbot.authors`):

  * finds the PR's TRACKING ISSUE: the issue whose body carries the hidden marker `<!-- depbot-pr <n> -->`
    (or whose title starts `<titlePrefix> #<n>`); none open and none closed for this very PR -> it FILES
    one (the marker, the PR link, the bot's summary, the configured labels) and posts a READY the planner
    accepts WITHOUT a hand: `READY: `<bot branch>` @ <tip>` first, then `stack: `<bot branch>` carries
    #<issue>` (train_lib.stack_declares, the one form `branchOwnership: issue` admits for a branch named
    otherwise) and `flag: none`;
  * puts it FIRST in priority (`priority: "first"`, a marked `first <issue>` row in the overrides file the
    queue already orders by; any other value is a label added to the issue);
  * when the bot moved the branch's tip (a force-push, a recreate on the same branch) it posts a new READY
    naming the new tip, so the queue's `readyTip: named` rule takes it; a READY naming a worker's own
    fixing branch stands (the worker's word supersedes the bot's);
  * when the bot replaced the PR by another (a new number, the same package key: ecosystem, directory and
    package or group, train_depbot.package_key), the older open tracking issue is SUPERSEDED: closed with a
    comment naming the new PR and its issue; an open tracking issue whose PR is gone is closed with what
    happened to the PR (merged, or closed by the bot);
  * a closed tracking issue for a PR that is still open is left alone (`closed-tracking`: the bumps landed
    another way, or the PR needs closing by hand); the queue files nothing twice.

When the train lands a tracking issue, the close-out (train_run.Cycle._close_out -> close_landed_pr) closes
the PR with a comment naming the landed sha, and the member branch is deleted as for every member.

The pass reports itself in one status segment (status_segment): `depbot: N open, oldest M passes`,
`depbot: 0 open`, or `depbot: unknown (pr list failed)` when the PR listing died, never a silent zero. A
pass is `everySeconds` (default 900): the daemon runs the pass at most that often, and the oldest PR's age
is counted in passes.

PRs are read and closed through `gh` (`AUTOCODER_DEPBOT_GH` names the binary; a test hands in a fake); issues
go through the tracker abstraction (train_lib.tracker -> issue-fns.sh), so any issue backend works.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone

import train_lib as T

DEFAULT_AUTHORS = ["dependabot[bot]"]
DEFAULT_TITLE_PREFIX = "Dependency update PR"
DEFAULT_EVERY = 900
DEFAULT_LIMIT = 100
PRIORITY_FIRST = "first"
PR_MARKER_RE = re.compile(r"<!--\s*depbot-pr\s+(\d+)\s*-->")
KEY_MARKER_RE = re.compile(r"<!--\s*depbot-key\s+(\S+)\s*-->")
HTML_COMMENT_RE = re.compile(r"<!--.*?-->", re.S)
OVERRIDE_MARK = "# depbot"          # the suffix of every overrides row this pass writes; hand rows are never touched
SUMMARY_LIMIT = 4000                # characters of the bot's PR body carried into the tracking issue
PR_FIELDS = "number,headRefName,headRefOid,createdAt,title,body,url,author,state"
VIEW_FIELDS = "number,state,mergedAt,mergeCommit,headRefName"


# ── configuration ───────────────────────────────────────────────────────────────────────
@dataclass
class Settings:
    enabled: bool = False
    authors: list = field(default_factory=lambda: list(DEFAULT_AUTHORS))
    labels: list = field(default_factory=list)   # the tracking issue's labels (default: readyLabels + the first anyLabels)
    priority: str = PRIORITY_FIRST               # `first`: an overrides row; any other value: a label added to the issue
    every: int = DEFAULT_EVERY                   # seconds between two passes from the daemon; the status line's "pass"
    title_prefix: str = DEFAULT_TITLE_PREFIX
    limit: int = DEFAULT_LIMIT                   # open PRs read per pass
    gh: list = field(default_factory=lambda: ["gh"])


def _login(name: str) -> str:
    """A bot's login as gh prints it (`app/dependabot`), as GitHub shows it (`dependabot[bot]`) or bare, one form."""
    n = str(name or "").strip().lower()
    n = n[4:] if n.startswith("app/") else n
    return n[:-5] if n.endswith("[bot]") else n


def settings(cfg: T.Config, env=None) -> Settings:
    """`train.depbot` of `.autocoder.json` (train_lib.load_config keeps the raw object). Absent or `enabled: false`
    is off: no PR is read, the status line carries no segment. `authors` must be a list of logins and `labels` a
    list of strings, else the config refuses to load, naming the key. `AUTOCODER_DEPBOT_GH` names the gh command."""
    env = {**os.environ, **dict(env or {})}
    raw = cfg.depbot
    if raw is None:
        return Settings(enabled=False, gh=shlex.split(env.get("AUTOCODER_DEPBOT_GH") or "gh"))
    authors = raw.get("authors", DEFAULT_AUTHORS)
    if not isinstance(authors, list) or not all(isinstance(a, str) and a.strip() for a in authors) or not authors:
        raise SystemExit(f"merge-train: train.depbot.authors must be a non-empty list of bot logins; got {authors!r}")
    labels = raw.get("labels")
    if labels is None:
        labels = list(cfg.ready_labels) + list(cfg.any_labels[:1])
    if not isinstance(labels, list) or not all(isinstance(x, str) for x in labels):
        raise SystemExit(f"merge-train: train.depbot.labels must be a list of labels; got {labels!r}")
    labels = list(dict.fromkeys(list(labels) + [x for x in cfg.ready_labels if x not in labels]))   # a tracking issue is always a READY item
    return Settings(
        enabled=bool(raw.get("enabled", True)),
        authors=[str(a) for a in authors],
        labels=labels,
        priority=str(raw.get("priority") or PRIORITY_FIRST),
        every=int(raw.get("everySeconds") if raw.get("everySeconds") is not None else DEFAULT_EVERY),
        title_prefix=str(raw.get("titlePrefix") or DEFAULT_TITLE_PREFIX),
        limit=int(raw.get("limit") or DEFAULT_LIMIT),
        gh=shlex.split(env.get("AUTOCODER_DEPBOT_GH") or "gh"),
    )


# ── the pull-request side: gh ───────────────────────────────────────────────────────────
class Pulls:
    """The PRs of the repository's GitHub remote, through `gh` run in the repo. A call that died in transport
    is retried like a tracker call (train_lib.TRACKER_TRANSPORT_ERROR, TRACKER_RETRY_PAUSES); any other failure
    raises RuntimeError naming the call."""

    def __init__(self, cfg: T.Config, st: Settings, sleep=time.sleep):
        self.cfg, self.st, self.sleep = cfg, st, sleep

    def _run(self, *args):
        attempt = 0
        while True:
            try:
                r = subprocess.run([*self.st.gh, *args], capture_output=True, text=True, cwd=str(self.cfg.repo))
            except OSError as e:
                raise RuntimeError(f"gh {' '.join(args[:2])} could not run ({self.st.gh[0]}): {e}")
            out = (r.stderr or r.stdout).strip()
            if r.returncode != 0 and attempt < len(T.TRACKER_RETRY_PAUSES) and T.TRACKER_TRANSPORT_ERROR.search(out):
                pause = T.TRACKER_RETRY_PAUSES[attempt]
                attempt += 1
                print(f"gh {' '.join(args[:2])} died in transport (attempt {attempt} of {len(T.TRACKER_RETRY_PAUSES) + 1}): "
                      f"{out[:160]}; retrying in {pause}s", file=sys.stderr)
                self.sleep(pause)
                continue
            if r.returncode != 0:
                raise RuntimeError(f"gh {' '.join(args[:2])} exited {r.returncode}: {out[:300]}")
            return r.stdout

    def list_open(self) -> list:
        """Every open PR by a configured author: [{number, head, tip, createdAt, title, body, url, author}]."""
        out = self._run("pr", "list", "--state", "open", "--limit", str(self.st.limit), "--json", PR_FIELDS)
        try:
            rows = json.loads(out or "[]")
        except ValueError as e:
            raise RuntimeError(f"gh pr list printed no JSON: {e}")
        want = {_login(a) for a in self.st.authors}
        prs = []
        for it in rows:
            author = it.get("author") or {}
            login = author.get("login") if isinstance(author, dict) else str(author)
            if _login(login) not in want:
                continue
            prs.append({"number": int(it["number"]), "head": it.get("headRefName") or "", "tip": it.get("headRefOid") or "",
                        "createdAt": it.get("createdAt") or "", "title": it.get("title") or "", "body": it.get("body") or "",
                        "url": it.get("url") or "", "author": login or ""})
        return sorted(prs, key=lambda p: p["number"])

    def view(self, number):
        """{number, state (OPEN|CLOSED|MERGED), mergedAt, mergeCommit, head} of one PR, or None when it cannot be read."""
        try:
            it = json.loads(self._run("pr", "view", str(number), "--json", VIEW_FIELDS) or "{}")
        except (RuntimeError, ValueError):
            return None
        mc = it.get("mergeCommit") or {}
        return {"number": int(it.get("number") or number), "state": str(it.get("state") or "").upper(), "mergedAt": it.get("mergedAt") or "",
                "mergeCommit": (mc.get("oid") if isinstance(mc, dict) else str(mc or "")) or "", "head": it.get("headRefName") or ""}

    def close(self, number, comment):
        self._run("pr", "close", str(number), "--comment", comment)


# ── the tracking issue ──────────────────────────────────────────────────────────────────
def package_key(head: str) -> str:
    """The update a PR carries, independent of its number and of the hash or version in its branch name:
    `dependabot/<ecosystem>/<dir...>/<group>-<hash10>` -> `<ecosystem>/<dir>/<group>`,
    `dependabot/<ecosystem>/<dir...>/<package>-<version>` -> `<ecosystem>/<dir>/<package>` (a root directory is `.`).
    Ecosystem and directory alone would fold a security update and a version update of one manifest into one item,
    so the group or package is part of it. Another bot's branch keeps its name less a trailing `-<hash10>` or
    `-<version>`."""
    strip = lambda s: re.sub(r"-[0-9a-f]{10}$", "", s) if re.search(r"-[0-9a-f]{10}$", s) else re.sub(r"-v?[0-9]+(\.[0-9]+)*([.+-][0-9A-Za-z.]+)?$", "", s)
    if not head.startswith("dependabot/"):
        return strip(head) or head
    parts = head[len("dependabot/"):].split("/")
    eco = parts[0]
    if len(parts) == 1:
        return f"{eco}/./{eco}"
    update = strip(parts[-1]) or parts[-1]
    directory = "/".join(parts[1:-1]) or "."
    return f"{eco}/{directory}/{update}"


def tracking_issues(cfg: T.Config, st: Settings) -> list:
    """Every issue the tracker lists (state all, newest 500) that tracks a PR: the body's `<!-- depbot-pr <n> -->`
    marker, else a title `<titlePrefix> #<n>`: [{number, pr, key, state, labels, title, body}], newest first."""
    r = T.tracker(cfg, "issue_list", "--state", "all", "--limit", "500")
    title_re = re.compile(rf"^{re.escape(st.title_prefix)}\s+#(\d+)(?![0-9])")
    out = []
    for it in json.loads(r.stdout or "[]"):
        body, title = it.get("body") or "", it.get("title") or ""
        m = PR_MARKER_RE.search(body) or title_re.match(title)
        if not m:
            continue
        k = KEY_MARKER_RE.search(body)
        labels = [(lb["name"] if isinstance(lb, dict) else lb) for lb in it.get("labels") or []]
        out.append({"number": int(it["number"]), "pr": int(m.group(1)), "key": k.group(1) if k else "", "state": str(it.get("state") or "OPEN").upper(),
                    "labels": labels, "title": title, "body": body})
    return sorted(out, key=lambda t: -t["number"])


def issue_body(st: Settings, pr: dict, key: str, integration: str) -> str:
    summary = HTML_COMMENT_RE.sub("", pr.get("body") or "").strip()
    if len(summary) > SUMMARY_LIMIT:
        summary = summary[:SUMMARY_LIMIT].rstrip() + "\n\n(summary truncated)"
    return (f"<!-- depbot-pr {pr['number']} -->\n<!-- depbot-key {key} -->\n"
            f"Tracking issue for dependency-update PR #{pr['number']} (branch `{pr['head']}`, by `{pr['author']}`), filed by the merge "
            f"queue's dependency-bot pass so a merge train lands it first in priority.\n\n"
            f"PR: {pr['url'] or '#' + str(pr['number'])}\nKey: `{key}`\n\n"
            f"The READY below names the bot branch with a `stack:` line, so the planner takes it without a hand; the gate is the review "
            f"for a dependency diff. A red gate returns it here for a person: fix on a branch and post a READY naming that branch, which "
            f"supersedes the bot's. When a train lands it, this issue closes with the landed `{integration}` sha, the PR is closed naming "
            f"it, and the bot branch is deleted. A new tip on the bot branch gets a new READY from the next pass; a PR the bot replaces "
            f"supersedes this issue.\n\n---\n\n{summary or '(the PR carries no summary)'}")


def ready_body(pr: dict, issue) -> str:
    """The READY the pass posts: READY first (a short lead naming no branch, sha or issue: train_lib.ready_lead), the
    bot branch in backticks with its tip right after it (train_lib.named_tip), the `stack:` line that makes the
    branch the issue's (train_lib.stack_declares) and the flag line. tests/test_merge_train_depbot.py pins this text
    against the planner's own parser, so the two cannot drift."""
    return (f"[depbot] READY: `{pr['head']}` @ {pr['tip'][:10]} (PR #{pr['number']}; queued by the dependency-bot pass, "
            f"the gate's dependency stages are the proof)\n\n"
            f"stack: `{pr['head']}` carries #{issue}\n\nflag: none")


def issue_title(st: Settings, pr: dict) -> str:
    return f"{st.title_prefix} #{pr['number']}: {pr['title']}"[:240]


# ── overrides: first in priority ────────────────────────────────────────────────────────
def sync_first_rows(path, issues: dict) -> bool:
    """Make the marked rows of the overrides file exactly `first <issue> # depbot PR #<n>` for <issues>
    ({issue: pr}); every other line (a hand `hold`, `first` or `retry` row, a comment) stays as it is. The file is
    rewritten only when it changes; True when it did."""
    lines = path.read_text().splitlines() if path.is_file() else []
    kept = [ln for ln in lines if OVERRIDE_MARK not in ln]
    rows = [f"first {i} {OVERRIDE_MARK} PR #{p}" for i, p in sorted(issues.items(), key=lambda kv: int(kv[0]))]
    new = kept + rows
    if new == lines:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(ln + "\n" for ln in new))
    return True


# ── the pass ────────────────────────────────────────────────────────────────────────────
def _utc(ts):
    try:
        d = datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
        return d if d.tzinfo else d.replace(tzinfo=timezone.utc)
    except ValueError:
        return None


class Pass:
    """One run over the open bot PRs. `rows` is one dict per PR ({pr, head, tip, issue, action, note}); `error` is
    set when the PR or issue listing failed (nothing is decided then); `closed` lists the tracking issues this
    pass closed ({issue, pr, why})."""

    def __init__(self, cfg: T.Config, st: Settings, pulls: Pulls = None, log=None, now=None, sleep=time.sleep):
        self.cfg, self.st = cfg, st
        self.pulls = pulls or Pulls(cfg, st, sleep=sleep)
        self.log = log or (lambda m: print(f"depbot: {m}", file=sys.stderr))
        self.now = now or datetime.now(timezone.utc)
        self.rows, self.closed, self.error = [], [], ""

    # -- tracker writes (each logged, never fatal to the pass: the next pass converges) --
    def _comment(self, issue, body):
        T.tracker(self.cfg, "issue_comment", str(issue), "--body", body)

    def _close(self, t, why):
        T.tracker(self.cfg, "issue_close", str(t["number"]), "--comment", f"{self.cfg.swarm}: {why}")
        self.closed.append({"issue": t["number"], "pr": t["pr"], "why": why})
        self.log(f"closed tracking issue #{t['number']} (PR #{t['pr']}): {why}")

    def _create(self, pr, key):
        r = T.tracker(self.cfg, "issue_create", "--title", issue_title(self.st, pr), "--body", issue_body(self.st, pr, key, self.cfg.integration),
                      *[x for lb in self.st.labels for x in ("--label", lb)])
        number = int(json.loads(r.stdout)["number"])
        self.log(f"filed tracking issue #{number} for PR #{pr['number']} (`{pr['head']}` @ {pr['tip'][:10]})")
        return number

    def _priority_label(self, t_labels, issue):
        if self.st.priority != PRIORITY_FIRST and self.st.priority not in t_labels:
            T.tracker(self.cfg, "issue_update", str(issue), "--add-label", self.st.priority)

    # -- the decision per PR --
    def _ready_state(self, issue, pr):
        """(action, note) for an open tracking issue: `ready` posted (none yet, or the tip moved), `tracked` (the
        READY names this tip), `worker-branch` (a READY names another branch: it stands), `no-branch` (the bot branch
        is not in this clone yet: nothing posted until a fetch sees it)."""
        if not T.branch_exists(self.cfg, pr["head"]):
            return "no-branch", f"`{pr['head']}` is not in this clone's remote refs yet (fetched before the bot pushed?); next pass"
        picked = T.pick_ready(self.cfg, T.ready_comments(json.loads(T.tracker(self.cfg, "issue_get", str(issue)).stdout)), issue)
        if picked and picked.get("branch") and picked["branch"] != pr["head"]:
            return "worker-branch", f"the newest READY names `{picked['branch']}`, which stands (a worker's branch supersedes the bot's)"
        if picked and picked.get("branch") == pr["head"] and (not picked.get("named") or pr["tip"].startswith(picked["named"])):
            return "tracked", "-"   # a READY at this tip, or a hand READY naming no sha (the queue takes the current tip)
        self._comment(issue, ready_body(pr, issue))
        why = "no READY yet" if not picked or not picked.get("branch") else f"the tip moved from `{(picked.get('named') or '?')[:10]}`"
        self.log(f"posted READY on #{issue} for PR #{pr['number']} at `{pr['tip'][:10]}` ({why})")
        return "ready", f"READY posted at `{pr['tip'][:10]}` ({why})"

    def run(self):
        try:
            prs = self.pulls.list_open()
        except RuntimeError as e:
            self.error = f"pr list failed: {e}"
            self.log(self.error)
            return self
        try:
            tracked = tracking_issues(self.cfg, self.st)
        except (RuntimeError, ValueError) as e:
            self.error = f"issue list failed: {e}"
            self.log(self.error)
            return self
        open_numbers = {p["number"] for p in prs}
        by_pr = {}
        for t in tracked:   # newest first, so the first seen per PR wins; an OPEN one beats a CLOSED one
            cur = by_pr.get(t["pr"])
            if cur is None or (cur["state"] != "OPEN" and t["state"] == "OPEN"):
                by_pr[t["pr"]] = t
        superseded = set()
        first = {}
        for pr in prs:
            key = package_key(pr["head"])
            t = by_pr.get(pr["number"])
            row = {"pr": pr["number"], "head": pr["head"], "tip": pr["tip"][:10], "createdAt": pr["createdAt"], "issue": "-", "action": "", "note": "-"}
            self.rows.append(row)
            try:
                if t and t["state"] != "OPEN":
                    row.update(issue=t["number"], action="closed-tracking",
                               note=f"tracking issue #{t['number']} is closed while PR #{pr['number']} is open: landed another way, or the PR needs closing by hand; nothing new is filed")
                    continue
                if t is None:
                    for old in tracked:
                        if old["state"] == "OPEN" and old["key"] and old["key"] == key and old["pr"] != pr["number"] and old["pr"] not in open_numbers and old["number"] not in superseded:
                            superseded.add(old["number"])
                            self._close(old, f"superseded: the bot replaced PR #{old['pr']} by PR #{pr['number']} (`{pr['head']}`), the same update "
                                             f"(`{key}`); the new PR gets its own tracking issue and this one lands nothing.")
                    number = self._create(pr, key)
                    row.update(issue=number, action="filed")
                    self._comment(number, ready_body(pr, number))
                    row["note"] = f"tracking issue #{number} filed, READY posted at `{pr['tip'][:10]}`"
                    labels = list(self.st.labels)
                else:
                    number, labels = t["number"], t["labels"]
                    action, note = self._ready_state(number, pr)
                    row.update(issue=number, action=action, note=note)
                self._priority_label(labels, number)
                first[number] = pr["number"]
            except RuntimeError as e:
                row.update(action="error", note=f"tracker call failed ({e}); the next pass tries again")
                self.log(f"PR #{pr['number']}: {row['note']}")
        # open tracking issues whose PR is gone: say what became of the PR, close the issue
        for t in tracked:
            if t["state"] != "OPEN" or t["pr"] in open_numbers or t["number"] in superseded:
                continue
            v = self.pulls.view(t["pr"])
            if v is None:
                self.log(f"tracking issue #{t['number']}: PR #{t['pr']} is not in the open list and could not be read; left as it is")
                first[t["number"]] = t["pr"]   # not this pass's to decide: its row stays
                continue
            try:
                if v["state"] == "MERGED":
                    self._close(t, f"PR #{t['pr']} is merged" + (f" as `{v['mergeCommit'][:10]}`" if v["mergeCommit"] else "") + "; nothing left to land here.")
                elif v["state"] == "CLOSED":
                    self._close(t, f"PR #{t['pr']} was closed without landing (the bot withdrew it, or a person closed it); nothing left to land here.")
                else:
                    first[t["number"]] = t["pr"]   # open, but not by a configured author any more, or a listing gap: left alone
            except RuntimeError as e:
                self.log(f"could not close tracking issue #{t['number']} ({e}); the next pass tries again")
                first[t["number"]] = t["pr"]
        if self.st.priority == PRIORITY_FIRST:
            try:
                sync_first_rows(self.cfg.overrides, first)
            except OSError as e:
                self.log(f"could not write the overrides file {self.cfg.overrides}: {e}")
        return self

    # -- the record the status line reads --
    def record(self) -> dict:
        return {"ts": self.now.strftime("%Y-%m-%dT%H:%M:%SZ"), "every": self.st.every, "error": self.error,
                "open": [{k: r[k] for k in ("pr", "head", "tip", "createdAt", "issue", "action")} for r in self.rows],
                "closed": self.closed}

    def save(self):
        path = self.cfg.state_dir / "depbot.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(self.record(), indent=1) + "\n")
        return path


def load_record(cfg: T.Config):
    path = cfg.state_dir / "depbot.json"
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text())
    except ValueError:
        return None


def status_segment(record, now=None) -> str:
    """`depbot: 0 open`, `depbot: N open, oldest M passes (#pr->#issue action, ...)`, `depbot: unknown (pr list failed)`
    (or `issue list failed`) when the pass could not read, `depbot: not run yet` without a record. A pass is the
    record's `every` seconds; the oldest PR's age (its createdAt) is counted in whole passes."""
    if not record:
        return "depbot: not run yet"
    if record.get("error"):
        return "depbot: unknown (" + record["error"].split(":")[0] + ")"
    rows = record.get("open") or []
    if not rows:
        return "depbot: 0 open"
    now = now or datetime.now(timezone.utc)
    every = max(1, int(record.get("every") or DEFAULT_EVERY))
    oldest = 0
    for r in rows:
        d = _utc(r.get("createdAt"))
        if d:
            oldest = max(oldest, int((now - d).total_seconds()))
    parts = ", ".join(f"#{r['pr']}->#{r['issue']} {r['action']}" for r in rows)
    return f"depbot: {len(rows)} open, oldest {oldest // every} passes ({parts})"


# ── the landing close-out: the PR behind a landed tracking issue ────────────────────────
def tracked_pr(cfg: T.Config, issue) -> int:
    """The PR number a tracking issue's body marker names, else 0 (not a tracking issue, or unreadable)."""
    try:
        body = json.loads(T.tracker(cfg, "issue_get", str(issue)).stdout).get("body") or ""
    except (RuntimeError, ValueError):
        return 0
    m = PR_MARKER_RE.search(body)
    return int(m.group(1)) if m else 0


def close_landed_pr(cfg: T.Config, st: Settings, issue, landed: str, branch: str, train: str = "", pulls: Pulls = None, log=None) -> int:
    """After a tracking issue landed: close its PR with a comment naming the landed sha (the branch is deleted by
    the member close-out, as for every member). Returns the PR number closed, 0 when the issue tracks none; a gh
    failure is logged, never raised (the next pass reports the PR as `closed-tracking` for a person)."""
    log = log or (lambda m: None)
    if not st.enabled:
        return 0
    pr = tracked_pr(cfg, issue)
    if not pr:
        return 0
    pulls = pulls or Pulls(cfg, st)
    try:
        pulls.close(pr, f"{cfg.swarm}: landed on `{cfg.integration}` as `{landed[:10]}`" + (f" in {train}" if train else "")
                        + f" through tracking issue #{issue} (branch `{branch}`); the merge train closes this PR and deletes the branch.")
        log(f"closed PR #{pr} (tracking issue #{issue}) as landed `{landed[:10]}`")
    except RuntimeError as e:
        log(f"could not close PR #{pr} after #{issue} landed as {landed[:10]} ({e}); close it by hand naming the sha")
    return pr
