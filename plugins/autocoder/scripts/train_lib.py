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
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
ISSUE_FNS = SCRIPTS / "issue-fns.sh"

DEFAULT_READY_RE = r"(^|[^A-Za-z])READY([^A-Za-z]|$)"
# `<prefix>/<name>`, no file extension in the last segment: `fix/7-x` is a branch, `docs/x.md` is not.
BRANCH_TOKEN_RE = re.compile(r"`([A-Za-z0-9_./-]+)`")
BRANCH_SHAPE_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+$")
FILE_EXT_RE = re.compile(r"(^|/)[^/]*\.[A-Za-z0-9]{1,6}$")
ENV_BRANCHES = {"master", "main", "develop", "uat", "prod"}
BLOCKQUOTE_COMMENT_RE = re.compile(r"^> \*\*(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}[^*]*)\*\* ?(.*)$")


# ── configuration ───────────────────────────────────────────────────────────────────────
@dataclass
class Config:
    repo: Path
    remote: str = "origin"
    integration: str = "master"
    ready_labels: list = field(default_factory=lambda: ["ready-for-review"])
    priority_labels: list = field(default_factory=lambda: ["P0", "P1", "P2", "P3"])
    lane_labels: list = field(default_factory=lambda: ["hotfix"])
    ready_pattern: str = DEFAULT_READY_RE
    note_pattern: str = ""          # a comment matching this is a coordinator's note, not a worker's READY
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


def load_config(repo, config_file=None, env=None) -> Config:
    """`.autocoder.json` of the main worktree, key `train`; environment overrides win.

    keys: readyLabels, priorityLabels, laneLabels, readyPattern, notePattern, size, staleDays,
    classifyLimit, integration, remote, stateDir, overridesFile, launchedFile, scratch,
    seedDirs, seedMarker, hooks{prepareScratch, mergeFault}.
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
        priority_labels=list(raw.get("priorityLabels") or ["P0", "P1", "P2", "P3"]),
        lane_labels=list(raw.get("laneLabels") or ["hotfix"]),
        ready_pattern=raw.get("readyPattern") or DEFAULT_READY_RE,
        note_pattern=raw.get("notePattern") or "",
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
    # The file backend keeps a comment as a blockquote appended to the body.
    cur = None
    for line in (issue.get("body") or "").splitlines():
        m = BLOCKQUOTE_COMMENT_RE.match(line)
        if m:
            cur = {"body": m.group(2), "createdAt": _iso(m.group(1))}
            out.append(cur)
        elif cur is not None and line.startswith("> "):
            cur["body"] += "\n" + line[2:]
        elif cur is not None and line.strip() == "":
            cur["body"] += "\n"
        else:
            cur = None
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


def pick_ready(cfg: Config, comments: list):
    """The READY an item is read from: {createdAt, body, branch|None, candidates}, or None.

    Of the comments that say READY, newest first, the first that names a branch existing on the
    remote wins. A comment naming no branch is passed over, so a coordinator's later "rebase and
    re-READY" note never shadows the worker's READY. When none names an existing branch, the newest
    READY that is not a coordinator's note stands (else the newest), so the no-branch report still
    quotes what the worker said.
    """
    ready_re = re.compile(cfg.ready_pattern)
    note_re = re.compile(cfg.note_pattern) if cfg.note_pattern else None
    ready = [c for c in reversed(comments) if ready_re.search(c["body"])]
    if not ready:
        return None
    newest_worker = next((c for c in ready if not (note_re and note_re.search(c["body"]))), ready[0])
    for c in ready:
        cands = branch_candidates(c["body"], {cfg.integration})
        for b in cands:
            if branch_exists(cfg, b):
                return {**c, "branch": b, "candidates": cands}
    return {**newest_worker, "branch": None, "candidates": branch_candidates(newest_worker["body"], {cfg.integration})}


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
    """A real merge of <ref> into the scratch HEAD (drivers honoured).

    Returns (verdict, detail): 'clean' (kept as a commit when `message` is given, else aborted),
    'conflict' (detail = unmerged paths, comma-joined), 'driver-fault' or 'generator-failed' (the
    `mergeFault` hook classified the merge output). On every non-clean verdict the scratch is
    cleared back to its HEAD: a half-merged tree must never reach the next candidate.
    """
    ident = ["-c", "user.name=autocoder-train", "-c", "user.email=autocoder-train@localhost"]
    keep = message is not None
    r = git(scratch, *ident, "merge", "--no-ff", *([] if keep else ["--no-commit"]), "-q", *(["-m", message] if keep else []), ref)
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
    """Open issues carrying every ready label: [{number, labels[], createdAt|None}]."""
    r = tracker(cfg, "issue_list", "--state", "open", "--label", cfg.ready_labels[0], "--limit", "500")
    items = []
    for it in json.loads(r.stdout or "[]"):
        labels = [(lb["name"] if isinstance(lb, dict) else lb) for lb in it.get("labels") or []]
        if str(it.get("state", "OPEN")).upper() != "OPEN" or not all(x in labels for x in cfg.ready_labels):
            continue
        items.append({"number": int(it["number"]), "labels": labels, "createdAt": it.get("createdAt")})
    return items


def classify(cfg: Config, ov: Overrides, issue, picked, in_flight, skip_merge_check=False, now=None):
    """(state, tip, note) of one item. States:

    no-branch   the READY names nothing on the remote (note: the names it tried)
    hold        a `hold <issue>` row
    in-flight   a gate for the issue is live
    in-train    the live train holds it
    train-dropped  a train dropped this tip; re-bank to offer it again
    stale       the READY is older than staleDays
    unchecked   not merge-checked: classifyLimit launchable items were already found
    on-master   the branch has no commit the integration branch lacks
    conflict    master does not merge cleanly into it (prefilter in an unowned path, else a real merge)
    driver-fault / generator-failed   the project's mergeFault hook classified the real merge
    launched    this queue already launched this tip and no `retry <issue>` row says again
    queue       launchable
    """
    branch = picked["branch"] if picked else None
    if not branch:
        tried = ",".join(picked["candidates"]) if picked else ""
        return ("no-branch", "-", tried)
    tip = short_tip(cfg, branch)
    if str(issue) in ov.hold:
        return ("hold", tip, ov.hold[str(issue)])
    if issue in in_flight:
        return ("in-flight", tip, "-")
    ts = train_state(cfg, issue, tip)
    if ts == "in-train":
        return ("in-train", tip, "in the live train")
    if ts == "train-dropped":
        return ("train-dropped", tip, "dropped from a train at this tip; re-bank to offer it again")
    if cfg.stale_days and picked.get("createdAt"):
        age = ((now or datetime.now(timezone.utc)) - datetime.fromisoformat(picked["createdAt"].replace("Z", "+00:00"))).days
        if age >= cfg.stale_days:
            return ("stale", tip, f"READY is {age} days old (limit {cfg.stale_days}); re-bank to offer it again")
    if skip_merge_check:
        return ("unchecked", tip, "not merge-checked: enough launchable items were found ahead of it (classifyLimit)")
    ref = cfg.remote_ref(branch)
    proof = landing_proof(cfg, ref)
    if proof:
        return ("on-master", tip, f"landing proof: {proof}")
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
    """The ordered queue: [{order, state, issue, branch, tip, rank, created, note}].

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
        state, tip, note = classify(cfg, ov, issue, picked, in_flight, skip_merge_check=skip, now=now)
        if not skip and state in ("queue", "launched"):
            found += 1
        rows.append({"order": n, "state": state, "issue": issue, "branch": picked["branch"] or "-", "tip": tip,
                     "rank": priority_rank(cfg, it["labels"]), "created": it["createdAt"] or "-", "note": note})
    return rows


def status_line(rows, when=None):
    when = when or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ")
    counts, nxt, nob = {}, None, []
    for r in rows:
        counts[r["state"]] = counts.get(r["state"], 0) + 1
        if r["state"] == "queue" and not nxt:
            nxt = f"#{r['issue']} {r['branch']} @ {r['tip']}"
        if r["state"] == "no-branch":
            nob.append(f"#{r['issue']}")
    order = ["queue", "in-flight", "in-train", "launched", "hold", "conflict", "generator-failed", "driver-fault",
             "stale", "train-dropped", "on-master", "unchecked", "no-branch"]
    line = f"{when} merge-train: {len(rows)} ready | next {nxt or 'none'}"
    for s in order:
        if counts.get(s):
            line += f" | {counts[s]} {s}" + (f" ({','.join(nob)})" if s == "no-branch" else "")
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


def plan_train(cfg: Config, rows, size=None):
    """Pick up to <size> members from the queue, each merged for real onto the integration branch
    plus the train so far, so the output is a train that assembles.

    Returns (rows, fault): rows are tab-separated records
      train  <issue> <branch> <tip> <note>      a member, in train order
      skip   <issue> <branch> <reason>          passed over; the planner goes on to the next candidate
      drop   <issue> <branch> <tip> <reason>    a generator failed on this candidate's merge: dropped for this plan
    and <fault> is a string when the planner itself failed (the scratch toolchain, a merge driver that
    could not run, a merge the prefilter called clean that failed): the plan is then NOT trustworthy and
    no branch is blamed.

    Decisions, in order, per candidate (each learned from a measured miss):
      1. a tip a train already dropped is skipped;
      2. the PREFILTER (merge-tree, no checkout) decides first, against the train so far: a conflict in a
         path no driver owns skips the candidate at once, with no merge attempted;
      3. a tip already contained in the train so far (a stack's lower slice carried by its tip) is a member
         that needs no merge: stacks land at their tip;
      4. otherwise ONE real merge both judges and accepts it (no separate verdict merge): a clean merge
         is kept, so the next candidate is judged against the train so far;
      5. a failed merge is CLEARED before the next candidate (a half-merged tree must never reach it), and a
         conflict from a prefilter-clean candidate is the planner's fault, not the branch's.
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
        issue, branch, tip, state = r["issue"], r["branch"], r["tip"], r["state"]
        if state not in ("queue", "launched"):
            if state == "driver-fault":
                return out, f"#{issue} ({branch}): {r['note']}"
            out.append(f"skip\t{issue}\t{branch}\t{state}: {r['note']}")
            continue
        if dropped_tip(cfg, issue) == tip:
            out.append(f"skip\t{issue}\t{branch}\tdropped from a train at this tip; re-bank to offer it again")
            continue
        ref = cfg.remote_ref(branch)
        if git(scratch, "merge-base", "--is-ancestor", ref, "HEAD").returncode == 0:
            out.append(f"train\t{issue}\t{branch}\t{tip}\tcarried by an earlier member (a stack lands at its tip)")
            members += 1
            continue
        pre = merge_prefilter(cfg, scratch, ref, "HEAD")
        if pre[0] == "conflict":
            out.append(f"skip\t{issue}\t{branch}\tconflicts with {cfg.integration} plus the train so far in {pre[1]} (merge-tree prefilter; no merge driver owns the path)")
            continue
        verdict, detail = merge_into(cfg, scratch, ref, message=f"candidate #{issue}")
        if verdict == "clean":
            out.append(f"train\t{issue}\t{branch}\t{tip}\t{r['note']}")
            members += 1
        elif verdict == "generator-failed":
            out.append(f"drop\t{issue}\t{branch}\t{tip}\ta generator failed on its merge with {cfg.integration} plus the train so far: {detail}")
        elif verdict == "driver-fault" or pre[0] == "clean":
            why = detail if verdict == "driver-fault" else f"the prefilter says clean onto the train so far but the real merge failed in {detail} (a merge driver did not do its job)"
            return out, f"#{issue} ({branch}): {why}"
        else:
            out.append(f"skip\t{issue}\t{branch}\tdoes not merge clean onto {cfg.integration} plus the train so far ({detail})")
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
