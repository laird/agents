"""train_lib.py -- the merge queue and train planner (library; CLI is merge-train.py).

A merge train lands several finished branches as ONE tree: the queue reads which issues are
READY from the issue tracker, the planner picks the next N whose branches merge cleanly onto the
integration branch plus the train so far, and the assembly/gate/publish steps (merge-train.py,
later slices) gate that one tree through merge-to-integration.sh.

This module is the first half: READY pickup, overrides, classification, ordering and the
planner. Nothing here knows a project; everything a project tunes is read from the `train`
object of its `.autocoder.json` (see `Config`) or from the overrides file.

Tracker access goes through issue-fns.sh (`issue_list`, `issue_get`, `issue_update`,
`issue_comment`), so every backend (github, ado, jira, file) works. The backends differ in what
a comment carries: GitHub gives `createdAt`, ADO and Jira only a body, the file backend appends
comments to the issue body as `> **<time>** text` blockquotes. `ready_comments()` normalises all
three into one oldest-first list; a missing timestamp is None, never a guess.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
ISSUE_FNS = SCRIPTS / "issue-fns.sh"

DEFAULT_READY_RE = r"(^|[^A-Za-z])READY([^A-Za-z]|$)"
# The block enqueue.sh prints: a READY carrying it was preflighted on a host that does not gate, never
# pre-checked, so the batch gate is its first full test. The queue takes it like any other READY and says so.
DEFAULT_PREFLIGHT_RE = r"=== preflight \(enqueue\.sh\): PASS ==="
READY_STATES = ("open", "working", "blocked", "all")   # the `issue_list --state` values a READY may be found under
READY_TIPS = ("named", "current")   # `readyTip`: hold the branch's tip to the sha the READY names, or take whatever tip it has
# The sha a READY names for its branch: the first hex word after the branch's name on the same line
# (`READY `feat/x` @ abc1234`, enqueue.sh's line, a prebank block's `tree abc1234 on origin/master ...`).
NAMED_SHA_RE = re.compile(r"(?<![0-9A-Za-z])[0-9a-f]{7,40}(?![0-9A-Za-z])")
PREFLIGHT_NOTE = "preflight READY (enqueued from a host that does not gate): the batch gate is its first full test"
# `<prefix>/<name>`, no file extension in the last segment: `fix/7-x` is a branch, `docs/x.md` is not.
BRANCH_TOKEN_RE = re.compile(r"`([A-Za-z0-9_./-]+)`")
BRANCH_SHAPE_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+$")
FILE_EXT_RE = re.compile(r"(^|/)[^/]*\.[A-Za-z0-9]{1,6}$")
ENV_BRANCHES = {"master", "main", "develop", "uat", "prod"}
BLOCKQUOTE_COMMENT_RE = re.compile(r"^> \*\*(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}[^*]*)\*\* ?(.*)$")
# Every merge the planner or the assembly makes runs with the repository's HOOKS OFF. A project's
# post-merge hook that regenerates the tree belongs to the ASSEMBLED tree, once (train_run's
# `regenerate`), never to a candidate probe, whose only outputs are the verdict and the
# driver-resolved tree. Measured on one project: the hook ran per accepted candidate, so a size-6
# plan over 17 candidates took 27 minutes. Merge DRIVERS are not hooks and still run.
HOOKS_OFF = ["-c", "core.hooksPath=/dev/null"]


# ── configuration ───────────────────────────────────────────────────────────────────────
@dataclass
class Config:
    repo: Path
    remote: str = "origin"
    integration: str = "master"
    ready_labels: list = field(default_factory=lambda: ["ready-for-review"])
    any_labels: list = field(default_factory=list)   # non-empty: an item must ALSO carry at least one of these
    ready_states: list = field(default_factory=lambda: ["open"])   # the tracker states a READY is listed under
    priority_labels: list = field(default_factory=lambda: ["P0", "P1", "P2", "P3"])
    lane_labels: list = field(default_factory=lambda: ["hotfix"])
    ready_pattern: str = DEFAULT_READY_RE
    note_pattern: str = ""          # a comment matching this is a coordinator's note, not a worker's READY
    preflight_pattern: str = DEFAULT_PREFLIGHT_RE   # a READY matching this was preflighted, not pre-checked (enqueue.sh)
    ready_tip: str = "named"        # `named`: a tip is held to the sha the READY names (same patches pass); `current`: any tip
    swarm: str = "merge-train"      # the train's own comments start with `<swarm>: `; the queue never reads them as READYs
    size: int = 4
    stale_days: int = 0             # 0 = a READY never goes stale
    classify_limit: int = 0         # 0 = merge-check every launchable item
    state_dir: Path = None
    overrides: Path = None
    launched: Path = None
    scratch: Path = None
    seed_dirs: list = field(default_factory=list)
    seed_marker: str = ".package-lock.json"
    hooks: dict = field(default_factory=dict)
    regenerated_drivers: list = field(default_factory=list)   # merge drivers of paths a landing regenerates
    regenerated_advice: str = ""    # appended to a regenerate-only item's note and comment (the project's remedy)

    @property
    def ref(self):
        return f"{self.remote}/{self.integration}"

    def remote_ref(self, branch):
        return f"refs/remotes/{self.remote}/{branch}"


def _main_worktree(repo: Path) -> Path:
    out = subprocess.run(["git", "-C", str(repo), "worktree", "list", "--porcelain"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.startswith("worktree "):
            return Path(line.split(" ", 1)[1])
    return repo


def _default_integration(repo: Path, remote: str) -> str:
    r = subprocess.run(["git", "-C", str(repo), "symbolic-ref", "--short", f"refs/remotes/{remote}/HEAD"], capture_output=True, text=True)
    if r.returncode == 0 and "/" in r.stdout:
        return r.stdout.strip().split("/", 1)[1]
    for b in ("master", "main"):
        if subprocess.run(["git", "-C", str(repo), "show-ref", "--verify", "--quiet", f"refs/remotes/{remote}/{b}"]).returncode == 0:
            return b
    return "master"


def _ready_states(raw, path) -> list:
    """`readyStates`: the tracker states (`issue_list --state`) the queue lists for READYs; default `["open"]`.

    A tracker's `open` is its CLAIMABLE queue, so the GitHub backend's `open` leaves out an issue
    carrying `working` (and every other lock or blocking label): a project whose convention keeps the
    claim label on an issue until its landing closes it lists `["open", "working"]`, or a READY posted
    while the issue is held is never an item. An absent or empty value is the default, like every
    other key; a value outside READY_STATES is a misspelling the tracker would refuse at list time,
    so it is refused here, naming the file."""
    states = list(raw or ["open"])
    bad = [s for s in states if s not in READY_STATES]
    if bad:
        raise SystemExit(f"merge-train: train.readyStates in {path} must be a list of {list(READY_STATES)}; got {states!r}")
    return states


def _ready_tip(raw, path) -> str:
    """`readyTip`: `named` (default) holds a branch's tip to the sha its READY names, taking a later tip only when
    it carries the same patches (a rebase or a fast-forward); `current` takes whatever tip the branch has."""
    value = str(raw or "named")
    if value not in READY_TIPS:
        raise SystemExit(f"merge-train: train.readyTip in {path} must be one of {list(READY_TIPS)}; got {value!r}")
    return value


def load_config(repo, config_file=None, env=None) -> Config:
    """`.autocoder.json` of the main worktree, key `train`; environment overrides win.

    keys: readyLabels, anyLabels, readyStates, readyTip, swarm, priorityLabels, laneLabels, readyPattern, notePattern, preflightPattern, size,
    staleDays, classifyLimit, integration, remote, stateDir, overridesFile, launchedFile, scratch,
    seedDirs, seedMarker, regeneratedMergeDrivers, regeneratedAdvice, hooks{prepareScratch, mergeFault};
    `enqueue` is enqueue.sh's (see there).
    """
    env = os.environ if env is None else env
    repo = Path(repo).resolve()
    path = Path(config_file) if config_file else _main_worktree(repo) / ".autocoder.json"
    raw = {}
    if path.is_file():
        try:
            raw = (json.loads(path.read_text()) or {}).get("train") or {}
        except (OSError, ValueError) as e:
            raise SystemExit(f"merge-train: cannot read the train config in {path}: {e}")
    remote = env.get("AUTOCODER_TRAIN_REMOTE") or raw.get("remote") or "origin"
    integration = env.get("AUTOCODER_TRAIN_INTEGRATION") or raw.get("integration") or _default_integration(repo, remote)
    url = subprocess.run(["git", "-C", str(repo), "remote", "get-url", remote], capture_output=True, text=True).stdout.strip() or str(repo)
    key = hashlib.sha256(f"{url.removesuffix('.git')}\n{integration}".encode()).hexdigest()[:16]
    state_root = Path(env.get("AUTOCODER_TRAIN_STATE") or raw.get("stateDir")
                      or Path(env.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "autocoder" / "train" / key)
    cfg = Config(
        repo=repo, remote=remote, integration=integration,
        ready_labels=list(raw.get("readyLabels") or ["ready-for-review"]),
        any_labels=list(raw.get("anyLabels") or []),
        ready_states=_ready_states(raw.get("readyStates"), path),
        priority_labels=list(raw.get("priorityLabels") or ["P0", "P1", "P2", "P3"]),
        lane_labels=list(raw.get("laneLabels") or ["hotfix"]),
        ready_pattern=raw.get("readyPattern") or DEFAULT_READY_RE,
        note_pattern=raw.get("notePattern") or "",
        preflight_pattern=raw.get("preflightPattern") or DEFAULT_PREFLIGHT_RE,
        ready_tip=_ready_tip(raw.get("readyTip"), path),
        swarm=str(raw.get("swarm") or "merge-train"),
        size=int(env.get("AUTOCODER_TRAIN_SIZE") or raw.get("size") or 4),
        stale_days=int(raw.get("staleDays") or 0),
        classify_limit=int(raw.get("classifyLimit") or 0),
        state_dir=state_root,
        overrides=Path(raw.get("overridesFile") or state_root / "overrides"),
        launched=Path(raw.get("launchedFile") or state_root / "launched.tsv"),
        scratch=Path(env.get("AUTOCODER_TRAIN_SCRATCH") or raw.get("scratch") or Path(env.get("TMPDIR") or "/tmp") / f"autocoder-train-scratch-{key}"),
        seed_dirs=list(raw.get("seedDirs") or []),
        seed_marker=raw.get("seedMarker") or ".package-lock.json",
        hooks=dict(raw.get("hooks") or {}),
        regenerated_drivers=list(raw.get("regeneratedMergeDrivers") or []),
        regenerated_advice=str(raw.get("regeneratedAdvice") or ""),
    )
    if cfg.size < 1:
        raise SystemExit(f"merge-train: train size must be a positive integer, got {cfg.size}")
    return cfg


# ── git and tracker plumbing ────────────────────────────────────────────────────────────
def git(repo, *args, check=False, input=None):
    r = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, input=input)
    if check and r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed in {repo}: {r.stderr.strip() or r.stdout.strip()}")
    return r


def tracker(cfg: Config, *args, check=True):
    """Run one `issue_*` function of issue-fns.sh from the repo (so issue-config.sh finds its config)."""
    r = subprocess.run(["bash", "-c", 'source "$1" || exit 99; shift; "$@"', "_", str(ISSUE_FNS), *args],
                       capture_output=True, text=True, cwd=str(cfg.repo))
    if check and r.returncode != 0:
        raise RuntimeError(f"tracker call `{' '.join(args)}` exited {r.returncode}: {(r.stderr or r.stdout).strip()[:300]}")
    return r


def branch_exists(cfg: Config, branch: str) -> bool:
    return git(cfg.repo, "show-ref", "--verify", "--quiet", cfg.remote_ref(branch)).returncode == 0


def short_tip(cfg: Config, branch: str) -> str:
    r = git(cfg.repo, "rev-parse", "--short=10", cfg.remote_ref(branch))
    return r.stdout.strip() if r.returncode == 0 else "-"


def landing_proof(cfg: Config, tip, ref=None) -> str:
    """How <ref> (default: the integration branch) carries <tip>'s work; "" when it does not.

    `ancestor`  tip is in ref's history (a merge or fast-forward landing);
    `patch`     every commit of tip is patch-equivalent to one in ref (a rebase landing, `git cherry`);
    `content`   merging tip into ref adds nothing: the merge's tree IS ref's tree (`git merge-tree`).
                A squash landing (one commit for a train of members, or for a branch with merge
                commits) is proven only this way, and it survives later landings that touch other
                hunks of the same files.
    A tip with no commit of its own (ref already is its tip) is `ancestor`.
    """
    ref = ref or cfg.ref
    if git(cfg.repo, "merge-base", "--is-ancestor", tip, ref).returncode == 0:
        return "ancestor"
    cherry = git(cfg.repo, "cherry", ref, tip)
    if cherry.returncode == 0 and not any(ln.startswith("+") for ln in cherry.stdout.splitlines()):
        return "patch"
    merged = git(cfg.repo, "merge-tree", "--write-tree", "--no-messages", ref, tip)
    if merged.returncode == 0 and merged.stdout.split("\n", 1)[0].strip() == git(cfg.repo, "rev-parse", f"{ref}^{{tree}}").stdout.strip():
        return "content"
    return ""


def regenerate_only(cfg: Config, ref, base=None):
    """The paths <ref> changes against <base> (default: the integration branch) when EVERY one of them
    is merged by one of `regeneratedMergeDrivers` (the `merge` attribute of <base>'s .gitattributes); None
    when any path is not, or when nothing changed, or when no driver is configured.

    A landing regenerates such a path from its sources (the project's regenerate step runs on the
    assembled tree), so a change that touches only regenerated paths lands NOTHING: the regenerated
    copy is what the sources say, whatever the branch wrote. Measured on one project: three bot PRs that
    edited only a generated export each took a tracking issue, a READY and a train slot, and the train
    landed an empty rebase. A branch that also edits a source (or .gitattributes itself) is not this.
    """
    if not cfg.regenerated_drivers:
        return None
    base = base or cfg.ref
    mb = git(cfg.repo, "merge-base", base, ref).stdout.strip() or base
    paths = [p for p in git(cfg.repo, "diff", "--name-only", "--no-renames", "-z", mb, ref).stdout.split("\0") if p]
    if not paths:
        return None
    # The attributes of <base>'s tree (git 2.40+); an older git reads the working tree's .gitattributes.
    stdin = "\0".join(paths) + "\0"   # on stdin, so a tree-wide diff never hits the argv limit
    r = git(cfg.repo, "check-attr", "-z", "--stdin", f"--source={base}", "merge", input=stdin)
    if r.returncode != 0:
        r = git(cfg.repo, "check-attr", "-z", "--stdin", "merge", input=stdin)
    if r.returncode != 0:
        return None
    fields = r.stdout.split("\0")
    drivers = {fields[i]: fields[i + 2] for i in range(0, len(fields) - 2, 3)}
    if all(drivers.get(p) in cfg.regenerated_drivers for p in paths):
        return paths
    return None


def regenerate_only_note(cfg: Config, paths):
    shown = ", ".join(f"`{p}`" for p in paths[:6]) + (f" and {len(paths) - 6} more" if len(paths) > 6 else "")
    return (f"changes only regenerated files ({shown}), which a landing regenerates from their sources: it would land nothing."
            + (f" {cfg.regenerated_advice}" if cfg.regenerated_advice else ""))


# ── READY pickup ────────────────────────────────────────────────────────────────────────
def _iso(ts: str) -> str:
    """'2026-11-21 02:00' (file backend) -> '2026-11-21T02:00:00Z'; an ISO string passes through."""
    ts = ts.strip()
    if re.match(r"^\d{4}-\d{2}-\d{2}T", ts):
        return ts
    try:
        return datetime.strptime(ts[:16], "%Y-%m-%d %H:%M").replace(tzinfo=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return ts


def ready_comments(issue: dict) -> list:
    """Every comment of an `issue_get` result, oldest first, as {body, createdAt|None}."""
    out = []
    for c in issue.get("comments") or []:
        if isinstance(c, dict):
            out.append({"body": c.get("body") or "", "createdAt": c.get("createdAt") or c.get("created_at") or None})
    if out:
        return out
    # The file backend keeps a comment as a blockquote appended to the body: `> **<time>** <first line>`,
    # and the comment's remaining lines follow as they were written (a multi-line READY: the block in a
    # fence). Comments are appended after the body, so once the first header is seen every line up to the
    # next header belongs to the comment before it; a `> ` prefix on such a line is stripped.
    cur = None
    for line in (issue.get("body") or "").splitlines():
        m = BLOCKQUOTE_COMMENT_RE.match(line)
        if m:
            cur = {"body": m.group(2), "createdAt": _iso(m.group(1))}
            out.append(cur)
        elif cur is not None:
            cur["body"] += "\n" + (line[2:] if line.startswith("> ") else line)
    for c in out:
        c["body"] = c["body"].strip()
    return out


def branch_candidates(body: str, extra_exclude=()) -> list:
    """Backticked branch-shaped names in order of appearance; `origin/` stripped, environment branches dropped."""
    seen, out = set(), []
    for tok in BRANCH_TOKEN_RE.findall(body or ""):
        name = re.sub(r"^origin/", "", tok)
        if not BRANCH_SHAPE_RE.match(name) or FILE_EXT_RE.search(name):
            continue
        if name in ENV_BRANCHES or name in extra_exclude or name in seen:
            continue
        seen.add(name)
        out.append(name)
    return out


def ready_basis(cfg: Config, body: str) -> str:
    """'preflight' when the READY carries enqueue.sh's PASS block (preflighted on a host that does not gate,
    never pre-checked: the batch gate is its first full test), else 'ready'."""
    return "preflight" if cfg.preflight_pattern and re.search(cfg.preflight_pattern, body or "") else "ready"


def named_tip(body: str, branch: str):
    """The sha a READY names for <branch>: the first hex word (7 to 40 digits) after the branch's backticked
    name on the same line, or None. Only that line counts: a sha elsewhere in the comment (a base the
    branch was rebased onto, another branch of a stack, a landed commit) is not this branch's tip."""
    for line in (body or "").splitlines():
        for token in (f"`{branch}`", f"`origin/{branch}`"):
            at = line.find(token)
            if at >= 0:
                m = NAMED_SHA_RE.search(line, at + len(token))
                return m.group(0) if m else None
    return None


def branch_patch_id(cfg: Config, rev) -> str:
    """One patch id for the whole work of <rev> against its merge base with the integration branch,
    with no context lines, so a rebase over a neighbouring edit keeps it and a change to the branch's own
    lines (new work, a conflict resolved) changes it. "" when <rev> adds nothing."""
    base = git(cfg.repo, "merge-base", cfg.ref, rev).stdout.strip()
    if not base:
        return ""
    diff = git(cfg.repo, "diff", "-U0", "--no-renames", "--no-color", "--no-ext-diff", base, rev).stdout
    out = git(cfg.repo, "patch-id", "--stable", input=diff).stdout.split()
    return out[0] if out else ""


def tip_relation(cfg: Config, branch: str, named: str):
    """How the branch's current remote tip relates to the sha its READY named: (relation, named_full).

    same          the tip is the named sha
    fast-forward  the named sha is in the tip's history and the tip carries the same patches (the branch
                  merged the integration branch in, or an empty commit)
    rebase        the tip carries the same patches on another base (a rebase, a squash, a reword)
    moved         the tip carries other work: its patches against the integration branch differ
    base          the named sha is in the integration branch's history (a base the READY mentioned,
                  or landed work): it names no tip of this branch
    unknown       this clone has no such commit (a force-push never fetched here, a typo)
    """
    r = git(cfg.repo, "rev-parse", "--verify", "--quiet", f"{named}^{{commit}}")
    if r.returncode != 0:
        return ("unknown", named)
    full = r.stdout.strip()
    tip = git(cfg.repo, "rev-parse", "--verify", "--quiet", f"{cfg.remote_ref(branch)}^{{commit}}").stdout.strip()
    if full == tip:
        return ("same", full)
    if git(cfg.repo, "merge-base", "--is-ancestor", full, cfg.ref).returncode == 0:
        return ("base", full)
    if branch_patch_id(cfg, full) != branch_patch_id(cfg, tip):
        return ("moved", full)
    ff = git(cfg.repo, "merge-base", "--is-ancestor", full, cfg.remote_ref(branch)).returncode == 0
    return ("fast-forward" if ff else "rebase", full)


def pick_ready(cfg: Config, comments: list):
    """The READY an item is read from: {createdAt, body, branch|None, candidates, named, basis}, or None.

    Of the comments that say READY, newest first, the first that names a branch existing on the
    remote wins. A comment naming no branch is passed over, so a coordinator's later "rebase and
    re-READY" note never shadows the worker's READY. When none names an existing branch, the newest
    READY that is not a coordinator's note stands (else the newest), so the no-branch report still
    quotes what the worker said. `basis` is ready_basis() of the comment picked: a preflight READY
    (enqueue.sh) is a first-class item, taken and gated like any other, and the row says what it is.
    `named` is the sha the READY names for the branch (named_tip), or None. The train's own comments
    (every one starts with `<swarm>: `) are never READYs: a `tip-moved` or drop comment quotes the branch,
    its tip and the word READY, and read as a READY it would name the very tip it refused.
    """
    ready_re = re.compile(cfg.ready_pattern)
    note_re = re.compile(cfg.note_pattern) if cfg.note_pattern else None
    own = f"{cfg.swarm}:"
    ready = [c for c in reversed(comments) if ready_re.search(c["body"]) and not c["body"].lstrip().startswith(own)]
    if not ready:
        return None
    newest_worker = next((c for c in ready if not (note_re and note_re.search(c["body"]))), ready[0])
    for c in ready:
        cands = branch_candidates(c["body"], {cfg.integration})
        for b in cands:
            if branch_exists(cfg, b):
                return {**c, "branch": b, "candidates": cands, "named": named_tip(c["body"], b), "basis": ready_basis(cfg, c["body"])}
    return {**newest_worker, "branch": None, "candidates": branch_candidates(newest_worker["body"], {cfg.integration}),
            "named": None, "basis": ready_basis(cfg, newest_worker["body"])}


# ── overrides, launched tips, train state ───────────────────────────────────────────────
def read_rows(path):
    p = Path(path) if path else None
    if not p or not p.is_file():
        return []
    return [ln.split() for ln in p.read_text().splitlines() if ln.strip() and not ln.lstrip().startswith("#")]


@dataclass
class Overrides:
    hold: dict
    first: list
    retry: set

    @classmethod
    def read(cls, path):
        hold, first, retry = {}, [], set()
        for row in read_rows(path):
            if len(row) < 2:
                continue
            kind, issue = row[0], row[1]
            if kind == "hold":
                hold[issue] = " ".join(row[2:])
            elif kind == "first" and issue not in first:
                first.append(issue)
            elif kind == "retry":
                retry.add(issue)
        return cls(hold, first, retry)

    def first_rank(self, issue):
        return self.first.index(str(issue)) + 1 if str(issue) in self.first else 999999


def launched_tip(cfg: Config, issue):
    tip = ""
    for row in read_rows(cfg.launched):
        if row[0] == str(issue) and len(row) > 1:
            tip = row[1]
    return tip


def train_state(cfg: Config, issue, tip):
    """'in-train' when the live train holds the issue, 'train-dropped' when a train dropped this very tip, else ''."""
    cur = cfg.state_dir / "current.tsv"
    if cur.is_file() and any(ln.split("\t")[0] == str(issue) for ln in cur.read_text().splitlines() if ln.strip()):
        return "in-train"
    dropped = ""
    f = cfg.state_dir / "dropped.tsv"
    if f.is_file():
        for ln in f.read_text().splitlines():
            parts = ln.split("\t")
            if parts and parts[0] == str(issue) and len(parts) > 1:
                dropped = parts[1]
    return "train-dropped" if dropped and dropped == tip else ""


# ── prefilter and real merge ────────────────────────────────────────────────────────────
def merge_prefilter(cfg: Config, repo, ref, base):
    """A millisecond verdict before any real merge, from `git merge-tree`.

    ('clean',)                      the real merge is clean too (a merge driver only ever runs on a
                                    path the merge found conflicting)
    ('conflict', unowned, owned)    paths no merge driver owns conflict: the real merge reports them too
    ('driver', owned)               every conflicting path is driver-owned: only the real merge decides
    ('unknown',)                    merge-tree could not say
    """
    r = git(repo, "merge-tree", "--write-tree", "--name-only", "--no-messages", base, ref)
    if r.returncode == 0:
        return ("clean",)
    if r.returncode != 1:
        return ("unknown",)
    paths = [p for p in r.stdout.splitlines()[1:] if p]
    if not paths:
        return ("unknown",)
    unowned, owned = [], []
    for p in paths:
        attr = ""
        for src in (base, ref):
            out = git(repo, "check-attr", f"--source={src}", "merge", "--", p).stdout
            attr = out.rsplit(": merge: ", 1)[-1].strip() if ": merge: " in out else ""
            if attr not in ("", "unspecified", "unset"):
                break
        (owned if attr not in ("", "unspecified", "unset") else unowned).append(p)
    return ("conflict", ",".join(unowned), ",".join(owned)) if unowned else ("driver", ",".join(owned))


def _abort_merge(repo):
    if git(repo, "merge", "--abort").returncode != 0:
        git(repo, "reset", "-q", "--hard", "HEAD")
    git(repo, "clean", "-fdq")


def merge_into(cfg: Config, scratch, ref, message=None):
    """A real merge of <ref> into the scratch HEAD (drivers honoured, hooks off: HOOKS_OFF).

    Returns (verdict, detail): 'clean' (kept as a commit when `message` is given, else aborted),
    'conflict' (detail = unmerged paths, comma-joined), 'driver-fault' or 'generator-failed' (the
    `mergeFault` hook classified the merge output). On every non-clean verdict the scratch is
    cleared back to its HEAD: a half-merged tree must never reach the next candidate.
    """
    ident = ["-c", "user.name=autocoder-train", "-c", "user.email=autocoder-train@localhost"]
    keep = message is not None
    r = git(scratch, *ident, *HOOKS_OFF, "merge", "--no-ff", *([] if keep else ["--no-commit"]), "-q", *(["-m", message] if keep else []), ref)
    if r.returncode == 0:
        if not keep:
            _abort_merge(scratch)
        return ("clean", "")
    paths = ",".join(git(scratch, "diff", "--name-only", "--diff-filter=U").stdout.split())
    out = (r.stdout or "") + (r.stderr or "")
    _abort_merge(scratch)
    hook = cfg.hooks.get("mergeFault")
    if hook:
        h = subprocess.run(["bash", "-c", hook], input=f"{paths}\n{out}", capture_output=True, text=True, cwd=str(scratch))
        first = (h.stdout.strip().splitlines() or [""])[0]
        kind, _, detail = first.partition("\t")
        if kind in ("driver-fault", "generator-failed"):
            return (kind, detail or "(no detail)")
    return ("conflict", paths or "?")


# ── the scratch tree ────────────────────────────────────────────────────────────────────
def scratch_prepare(cfg: Config, ref=None):
    """A detached worktree of the repo at <ref>, reset and cleaned; created on first use."""
    ref = ref or cfg.ref
    s = cfg.scratch
    if not (s / ".git").exists():
        shutil.rmtree(s, ignore_errors=True)
        git(cfg.repo, "worktree", "prune")
        git(cfg.repo, "worktree", "add", "-q", "--detach", str(s), ref, check=True)
    else:
        git(s, "merge", "--abort")
        git(s, "checkout", "-q", "--detach", ref, check=True)
        git(s, "reset", "-q", "--hard", ref, check=True)
        git(s, "clean", "-fdq", check=True)
    return s


def seed_scratch(cfg: Config, scratch):
    """Hardlink-copy each configured directory (an installed dependency tree) from the repo into the scratch.

    A copy, never a symlink: a generator that writes under it must land in the scratch, not in the
    tree every gate reads. A copy is replaced when its marker file is a different inode than the
    repo's (a reinstall replaced it). Returns notes for what could not be seeded.
    """
    notes = []
    for d in cfg.seed_dirs:
        src, dst = cfg.repo / d, scratch / d
        if dst.is_symlink():
            dst.unlink()
        if not src.is_dir():
            notes.append(f"{d} is not present in {cfg.repo}; a generator that needs it fails in the scratch")
            continue
        if dst.is_dir():
            ms, md = src / cfg.seed_marker, dst / cfg.seed_marker
            if ms.exists() and md.exists() and os.stat(ms).st_ino == os.stat(md).st_ino:
                continue
            shutil.rmtree(dst)
        dst.parent.mkdir(parents=True, exist_ok=True)
        r = subprocess.run(["cp", "-al", str(src), str(dst)], capture_output=True, text=True)
        if r.returncode != 0:  # a different filesystem cannot hardlink: fall back to a real copy
            r = subprocess.run(["cp", "-a", str(src), str(dst)], capture_output=True, text=True)
        if r.returncode != 0:
            notes.append(f"could not copy {d} into the scratch: {r.stderr.strip()[:200]}")
    return notes


def prepare_toolchain(cfg: Config, scratch):
    """Seed the scratch and run the project's `prepareScratch` hook; (ok, reason).

    The planner's real merges run the repo's merge drivers, and a driver whose generator cannot run
    falls back to a textual merge that reads as a conflict: the toolchain is made and proven BEFORE
    any candidate is judged, never after.
    """
    seed_scratch(cfg, scratch)
    hook = cfg.hooks.get("prepareScratch")
    if hook:
        r = subprocess.run(["bash", "-c", hook], capture_output=True, text=True, cwd=str(scratch))
        if r.returncode != 0:
            tail = (r.stdout + r.stderr).strip().splitlines()[-1:] or ["(no output)"]
            return False, f"prepareScratch exited {r.returncode}: {tail[0][:200]}"
    return True, ""


# ── the queue ───────────────────────────────────────────────────────────────────────────
def priority_rank(cfg: Config, labels):
    for i, p in enumerate(cfg.priority_labels):
        if p in labels:
            return i + 1
    return len(cfg.priority_labels) + 1


def list_items(cfg: Config):
    """Open issues carrying every ready label, and at least one `anyLabels` label when any are
    configured, listed under each `readyStates` tracker state: [{number, labels[], createdAt|None}].

    `readyLabels` is "all of" (the READY state); `anyLabels` is "at least one of" (a scope: several
    hosts or teams feed one queue, each tagging its READYs with its own label, and a queue takes the
    union it is configured for). An item carrying none of the `anyLabels` is not this queue's.
    `readyStates` is the tracker states the queue lists (default `["open"]`): a backend's `open` is
    its claimable queue, which leaves out a claimed (`working`) issue, so a project whose claim label
    stays on the issue until it lands lists `["open", "working"]`. An issue listed under two states
    is one item; one the tracker itself reports closed is none."""
    items, seen = [], set()
    for state in cfg.ready_states:
        r = tracker(cfg, "issue_list", "--state", state, "--label", cfg.ready_labels[0], "--limit", "500")
        for it in json.loads(r.stdout or "[]"):
            number = int(it["number"])
            labels = [(lb["name"] if isinstance(lb, dict) else lb) for lb in it.get("labels") or []]
            if number in seen or str(it.get("state", "OPEN")).upper() != "OPEN" or not all(x in labels for x in cfg.ready_labels):
                continue
            if cfg.any_labels and not any(x in labels for x in cfg.any_labels):
                continue
            seen.add(number)
            items.append({"number": number, "labels": labels, "createdAt": it.get("createdAt")})
    return items


def classify(cfg: Config, ov: Overrides, issue, picked, in_flight, skip_merge_check=False, now=None):
    """(state, tip, note, named) of one item; `named` is followed_tip()'s (kind, text) for a tip that is not
    the sha the READY named (("", "") when there is nothing to say); plan_queue appends the text to the note. States:

    no-branch   the READY names nothing on the remote (note: the names it tried)
    hold        a `hold <issue>` row
    in-flight   a gate for the issue is live
    in-train    the live train holds it
    train-dropped  a train dropped this tip; re-bank to offer it again
    stale       the READY is older than staleDays
    unchecked   not merge-checked: classifyLimit launchable items were already found
    on-master   the branch has no commit the integration branch lacks
    tip-moved   the READY named a sha and the branch's tip carries other work (`readyTip: named`): not READY
                until one is posted at this tip. A tip that carries the SAME patches as the named sha (a
                rebase onto a moved integration branch, a merge of it into the branch) is classified as any
                other, and the note says which tip was taken and why; a cycle tells the issue once per tip.
    regenerate-only  every path it changes is merged by a `regeneratedMergeDrivers` driver, so a landing
                would regenerate them from their sources and land nothing (note: the files); never planned
                at this tip (a cycle tells the issue once per tip)
    conflict    master does not merge cleanly into it (prefilter in an unowned path, else a real merge)
    driver-fault / generator-failed   the project's mergeFault hook classified the real merge
    launched    this queue already launched this tip and no `retry <issue>` row says again
    queue       launchable
    """
    branch = picked["branch"] if picked else None
    if not branch:
        tried = ",".join(picked["candidates"]) if picked else ""
        return ("no-branch", "-", tried, ("", ""))
    tip = short_tip(cfg, branch)
    if str(issue) in ov.hold:
        return ("hold", tip, ov.hold[str(issue)], ("", ""))
    if issue in in_flight:
        return ("in-flight", tip, "-", ("", ""))
    ts = train_state(cfg, issue, tip)
    if ts == "in-train":
        return ("in-train", tip, "in the live train", ("", ""))
    if ts == "train-dropped":
        return ("train-dropped", tip, "dropped from a train at this tip; re-bank to offer it again", ("", ""))
    if cfg.stale_days and picked.get("createdAt"):
        age = ((now or datetime.now(timezone.utc)) - datetime.fromisoformat(picked["createdAt"].replace("Z", "+00:00"))).days
        if age >= cfg.stale_days:
            return ("stale", tip, f"READY is {age} days old (limit {cfg.stale_days}); re-bank to offer it again", ("", ""))
    if skip_merge_check:
        return ("unchecked", tip, "not merge-checked: enough launchable items were found ahead of it (classifyLimit)", ("", ""))
    ref = cfg.remote_ref(branch)
    proof = landing_proof(cfg, ref)
    if proof:
        return ("on-master", tip, f"landing proof: {proof}", ("", ""))
    named = followed_tip(cfg, branch, picked.get("named"), tip)
    if named[0] == "moved":
        return ("tip-moved", tip, named[1], ("", ""))
    state, tip, note = _classify_merge(cfg, ov, issue, ref, tip)
    return (state, tip, note, named)


def followed_tip(cfg: Config, branch, named, tip):
    """The named-tip verdict for a classified item: (kind, text).

    ("", "")            nothing to say: the READY names no sha, `readyTip` is `current`, the tip is the named sha,
                        or the sha names a base of the integration branch rather than a tip of this branch
    ("taken", note)     the tip carries the named sha's patches on another base or ahead of it: taken, the
                        note says which tip and why (the cycle tells the issue once per tip)
    ("unknown", note)   this clone cannot resolve the sha: the current tip is taken and the note says so
    ("moved", why)      the tip carries other work: refused as `tip-moved` until a READY names it
    """
    if cfg.ready_tip != "named" or not named:
        return ("", "")
    relation, full = tip_relation(cfg, branch, named)
    short = full[:10]
    if relation in ("same", "base"):
        return ("", "")
    if relation == "unknown":
        return ("unknown", f"READY names `{short}`, which this clone cannot resolve; taking the branch's current tip `{tip}`")
    if relation == "moved":
        return ("moved", f"the tip `{tip}` carries work the READY at `{short}` did not name (the patches differ); "
                         f"re-post READY at this tip (a rebase or fast-forward of the same patches is taken without one)")
    kind = "fast-forwarded" if relation == "fast-forward" else "rebased"
    return ("taken", f"READY named `{short}`, taking the {kind} tip `{tip}`: same patches")


def _classify_merge(cfg: Config, ov: Overrides, issue, ref, tip):
    """The merge-dependent tail of classify(): regenerate-only, the prefilter, the real merge, launched, queue."""
    regen = regenerate_only(cfg, ref)
    if regen:
        return ("regenerate-only", tip, regenerate_only_note(cfg, regen))
    pre = merge_prefilter(cfg, cfg.repo, ref, cfg.ref)
    if pre[0] == "conflict":
        owned = f"; a merge driver owns the other conflicting path(s) {pre[2]}, which the real merge decides" if pre[2] else ""
        return ("conflict", tip, f"needs rebase (conflicts in {pre[1]}; merge-tree prefilter, no merge driver owns them{owned})")
    if pre[0] != "clean":
        scratch = scratch_prepare(cfg)
        ok, why = prepare_toolchain(cfg, scratch)
        if not ok:
            return ("driver-fault", tip, f"the scratch toolchain is not working ({why}); a fault of the scratch, not of the branch")
        verdict, detail = merge_into(cfg, scratch, ref)
        if verdict == "driver-fault":
            return ("driver-fault", tip, f"the merge driver could not run in the scratch ({detail}); a fault of the scratch, not of the branch")
        if verdict == "generator-failed":
            return ("generator-failed", tip, f"a generator failed on its merge with {cfg.integration} ({detail}); regenerate, commit, re-bank")
        if verdict != "clean":
            return ("conflict", tip, f"needs rebase (real merge conflicts in {detail})")
    last = launched_tip(cfg, issue)
    if last and last == tip and str(issue) not in ov.retry:
        return ("launched", tip, f'awaiting its gate; add "retry {issue}" to re-gate')
    return ("queue", tip, "-")


def plan_queue(cfg: Config, in_flight=(), now=None):
    """The ordered queue: [{order, state, issue, branch, tip, rank, created, note, basis, named, followed}].

    `basis` is `preflight` for a READY enqueue.sh posted from a host that does not gate (the batch gate is
    its first full test; a launchable one's note says so), else `ready`. `named` is the sha the READY names
    for the branch (or `-`); `followed` is the note of a tip taken in its place (same patches, rebased or
    fast-forwarded), else "" (the note carries it too; the cycle tells the issue once per tip).

    Order: `first` rows in file order, then the lane (lane-labelled items), then priority rank, then
    age (the tracker's createdAt when it reports one, else the issue number), then number. The order
    needs no classification, so it is sorted first and classified in that order: once classifyLimit
    launchable items are found the rest skip the merge check (cheap states still show).
    """
    ov = Overrides.read(cfg.overrides)
    items = list_items(cfg)
    in_flight = {int(x) for x in in_flight}

    def key(it):
        lane = 0 if any(lb in cfg.lane_labels for lb in it["labels"]) else 1
        return (ov.first_rank(it["number"]), lane, priority_rank(cfg, it["labels"]), it["createdAt"] or "", it["number"])

    rows, found = [], 0
    for n, it in enumerate(sorted(items, key=key), 1):
        issue = it["number"]
        picked = pick_ready(cfg, ready_comments(json.loads(tracker(cfg, "issue_get", str(issue)).stdout)))
        if picked is None:
            continue   # labelled ready-for-review but says READY nowhere: not an item
        skip = bool(cfg.classify_limit) and found >= cfg.classify_limit
        state, tip, note, (named_kind, named_text) = classify(cfg, ov, issue, picked, in_flight, skip_merge_check=skip, now=now)
        if not skip and state in ("queue", "launched"):
            found += 1
        basis = picked.get("basis") or "ready"
        parts = ([PREFLIGHT_NOTE] if basis == "preflight" and state == "queue" else []) + ([note] if note != "-" else []) + ([named_text] if named_text else [])
        rows.append({"order": n, "state": state, "issue": issue, "branch": picked["branch"] or "-", "tip": tip,
                     "rank": priority_rank(cfg, it["labels"]), "created": it["createdAt"] or "-", "note": "; ".join(parts) or "-", "basis": basis,
                     "named": (picked.get("named") or "-"), "followed": named_text if named_kind == "taken" else ""})
    return rows


def status_line(rows, when=None):
    when = when or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ")
    counts, nxt, nob, preflight = {}, None, [], 0
    for r in rows:
        counts[r["state"]] = counts.get(r["state"], 0) + 1
        preflight += 1 if r.get("basis") == "preflight" else 0
        if r["state"] == "queue" and not nxt:
            nxt = f"#{r['issue']} {r['branch']} @ {r['tip']}"
        if r["state"] == "no-branch":
            nob.append(f"#{r['issue']}")
    order = ["queue", "in-flight", "in-train", "launched", "hold", "conflict", "generator-failed", "driver-fault",
             "stale", "train-dropped", "tip-moved", "on-master", "regenerate-only", "unchecked", "no-branch"]
    line = f"{when} merge-train: {len(rows)} ready | next {nxt or 'none'}"
    for s in order:
        if counts.get(s):
            line += f" | {counts[s]} {s}" + (f" ({','.join(nob)})" if s == "no-branch" else "")
    if preflight:
        line += f" | {preflight} preflight"
    return line


# ── the planner ─────────────────────────────────────────────────────────────────────────
def dropped_tip(cfg: Config, issue):
    f = cfg.state_dir / "dropped.tsv"
    tip = ""
    if f.is_file():
        for ln in f.read_text().splitlines():
            p = ln.split("\t")
            if p and p[0] == str(issue) and len(p) > 1:
                tip = p[1]
    return tip


def judge_candidate(cfg: Config, scratch, r):
    """One candidate against the scratch (the integration branch plus the train so far).

    Returns (kind, text): kind 'train', 'skip' or 'drop' with text the planner's row, or 'fault' with
    text the reason the plan cannot be trusted. Decisions, in order (each learned from a measured miss):
      1. a tip a train already dropped is skipped;
      2. a tip already contained in the train so far (a stack's lower slice carried by its tip) is a member
         that needs no merge: stacks land at their tip;
      3. the PREFILTER (merge-tree, no checkout) decides next: a conflict in a path no driver owns skips the
         candidate at once, with no merge attempted;
      4. otherwise ONE real merge, hooks off, both judges and accepts it (no separate verdict merge): a clean
         merge is kept, so the next candidate is judged against the train so far;
      5. a failed merge is CLEARED before the next candidate (a half-merged tree must never reach it), and a
         conflict from a prefilter-clean candidate is the planner's fault, not the branch's.
    """
    issue, branch, tip = r["issue"], r["branch"], r["tip"]
    if dropped_tip(cfg, issue) == tip:
        return "skip", f"skip\t{issue}\t{branch}\tdropped from a train at this tip; re-bank to offer it again"
    ref = cfg.remote_ref(branch)
    if git(scratch, "merge-base", "--is-ancestor", ref, "HEAD").returncode == 0:
        return "train", f"train\t{issue}\t{branch}\t{tip}\tcarried by an earlier member (a stack lands at its tip)"
    pre = merge_prefilter(cfg, scratch, ref, "HEAD")
    if pre[0] == "conflict":
        return "skip", f"skip\t{issue}\t{branch}\tconflicts with {cfg.integration} plus the train so far in {pre[1]} (merge-tree prefilter; no merge driver owns the path)"
    verdict, detail = merge_into(cfg, scratch, ref, message=f"candidate #{issue}")
    if verdict == "clean":
        return "train", f"train\t{issue}\t{branch}\t{tip}\t{r['note']}"
    if verdict == "generator-failed":
        return "drop", f"drop\t{issue}\t{branch}\t{tip}\ta generator failed on its merge with {cfg.integration} plus the train so far: {detail}"
    if verdict == "driver-fault" or pre[0] == "clean":
        why = detail if verdict == "driver-fault" else f"the prefilter says clean onto the train so far but the real merge failed in {detail} (a merge driver did not do its job)"
        return "fault", f"#{issue} ({branch}): {why}"
    return "skip", f"skip\t{issue}\t{branch}\tdoes not merge clean onto {cfg.integration} plus the train so far ({detail})"


def plan_train(cfg: Config, rows, size=None, on_candidate=None):
    """Pick up to <size> members from the queue, each merged for real onto the integration branch
    plus the train so far, so the output is a train that assembles.

    Returns (rows, fault): rows are tab-separated records
      train  <issue> <branch> <tip> <note>      a member, in train order
      skip   <issue> <branch> <reason>          passed over; the planner goes on to the next candidate
      drop   <issue> <branch> <tip> <reason>    a generator failed on this candidate's merge: dropped for this plan
    and <fault> is a string when the planner itself failed (the scratch toolchain, a merge driver that
    could not run, a merge the prefilter called clean that failed): the plan is then NOT trustworthy and
    no branch is blamed.

    `on_candidate(issue, kind, seconds)` is called for every launchable candidate the planner judged
    (judge_candidate's decisions), with the seconds its probe took: the planning time of a cycle is
    their sum; merge-train-run.py records them as `plan` rows of the landing timings.

    Every merge runs hooks off (HOOKS_OFF): a project's regeneration runs ONCE on the assembled tree.
    """
    size = size or cfg.size
    out, members = [], 0
    scratch = scratch_prepare(cfg)
    ok, why = prepare_toolchain(cfg, scratch)
    if not ok:
        return out, f"the scratch toolchain is not working ({why}); fix the scratch at {scratch}, then plan again"
    for r in rows:
        if members >= size:
            break
        issue, branch, state = r["issue"], r["branch"], r["state"]
        if state not in ("queue", "launched"):
            if state == "driver-fault":
                return out, f"#{issue} ({branch}): {r['note']}"
            out.append(f"skip\t{issue}\t{branch}\t{state}: {r['note']}")
            continue
        t0 = time.monotonic()
        kind, text = judge_candidate(cfg, scratch, r)
        if on_candidate:
            on_candidate(issue, kind, round(time.monotonic() - t0, 1))
        if kind == "fault":
            return out, text
        out.append(text)
        if kind == "train":
            members += 1
    return out, None


# ── reopening an issue closed under a newer READY ───────────────────────────────────────
def newer_ready(cfg: Config, issue, member_branch, landed, launched=None):
    """A landing closes the member's issue, but a stack's issue can carry a newer READY naming a branch the
    landing did not carry (the lower slice closed the issue while the upper slice was READY on it).

    Returns {branch, tip, createdAt} when the issue's newest READY that names an existing branch names one whose
    tip is NOT an ancestor of <landed> and that is either another branch than the member's or was posted after
    <launched> (needs comment timestamps; a backend without them reopens only for another branch). None otherwise.
    """
    picked = pick_ready(cfg, ready_comments(json.loads(tracker(cfg, "issue_get", str(issue)).stdout)))
    if not picked or not picked["branch"]:
        return None
    branch = picked["branch"]
    if branch == member_branch and not (launched and picked["createdAt"] and picked["createdAt"] > launched):
        return None
    tip = git(cfg.repo, "rev-parse", "--verify", "--quiet", cfg.remote_ref(branch) + "^{commit}").stdout.strip()
    if not tip or landing_proof(cfg, tip, landed):
        return None
    return {"branch": branch, "tip": tip, "createdAt": picked["createdAt"] or ""}


def reopen_if_newer_ready(cfg: Config, issue, member_branch, landed, launched=None, who="merge-train"):
    """Mechanically reopen <issue> (state open, ready labels back) when newer_ready() finds one; True when reopened."""
    n = newer_ready(cfg, issue, member_branch, landed, launched)
    if not n:
        return False
    tracker(cfg, "issue_update", str(issue), "--status", "open")
    for lb in cfg.ready_labels:
        tracker(cfg, "issue_update", str(issue), "--add-label", lb)
    tracker(cfg, "issue_comment", str(issue), "--body",
            f"{who}: reopened. This issue closed when `{member_branch}` landed as `{landed[:10]}`, but its newest READY "
            f"names `{n['branch']}` @ `{n['tip'][:10]}`, which that landing does not carry; it rejoins the queue at that tip.")
    return True
