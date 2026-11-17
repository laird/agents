#!/usr/bin/env python3
"""review-corpus.py — a review test set built from real failures (#167).

WHY THIS EXISTS:
  A change to the pre-landing reviewer (its prompt, REVIEW.md, its tools or its
  model) can't be judged by reading it. This scores the reviewer against diffs
  whose answer is known:

  * culprit cases: a push the post-merge sentinel (main-sentinel.sh) found red and
    reverted. The revert commit carries `Autocoder-Reverts: <culprit>` and
    `Autocoder-Reverts-Issue: <n>` trailers and a `Range <prev-good>..<culprit>`
    line, so the culprit diff is exact, not guessed from commit messages. A good
    reviewer flags it.
  * clean cases: diffs that landed and stayed green. A good reviewer passes them;
    flagging one is a false alarm.

  Run `score` before and after every change to the reviewer, and drop changes that
  don't raise the score.

LAYOUT (tests/review_corpus/, see its README):
  cases/<id>/case.json   {"id", "kind": "culprit"|"clean", "expect": "flag"|"pass",
                          "source", "issue", "commits", "note"}
  cases/<id>/diff.patch  what the reviewer sees
  cases/<id>/fix.patch   culprits only, when found: what the fix had to change.
                         For a sentinel revert, the issue's own commits (subject
                         `#<n>:` or `Fix #<n>:`) that landed after the work was
                         re-applied with `git revert <revert>`; for a reversed
                         fix, the fix commit itself

USAGE
  review-corpus.py harvest [--repo DIR] [--ref REF] [--corpus DIR]
      Add a culprit case for every sentinel revert reachable from REF
      (default origin/master, else HEAD). Existing cases are left alone.
  review-corpus.py add --clean SHA [--note TEXT]
      Add the diff of commit SHA as a clean case.
  review-corpus.py add --reversed-fix SHA [--note TEXT]
      Add the reverse of bug-fix commit SHA as a culprit case: undoing a fix puts
      back a defect someone actually shipped. Use it to seed the set before the
      sentinel has reverted anything.
  review-corpus.py score [--reviewer CMD] [--corpus DIR] [--json]
                         [--baseline FILE [--allow-equal]] [--save FILE]
      Run the reviewer on every case and score it. CMD gets the diff on stdin and
      REVIEW_CASE_DIR / REVIEW_RULES in its environment, and must print a line
      `Verdict: flag` or `Verdict: pass` (the last such line counts). The default,
      `claude`, runs `claude -p` with REVIEW.md as the rules.
      score = catch rate - false-alarm rate. A case the reviewer could not answer
      (no Verdict line, crash, timeout) is an error: wrong for either kind, so it
      is never a catch and always a false alarm, and any error fails the run.
      The corpus must hold both kinds, or one rate means nothing. With
      --baseline, exit 1 unless the score beats the saved one (--allow-equal: or
      equals it).

  --corpus and --rules are relative to --repo (default: the current directory).

EXIT: 0 ok; 1 failed, any reviewer error, or no improvement over --baseline; 2 usage.
"""

import argparse
import json
import os
import pathlib
import re
import shlex
import subprocess
import sys

DEFAULT_CORPUS = "tests/review_corpus"
VERDICT_RE = re.compile(r"^\s*Verdict:\s*(flag|pass)\b", re.I | re.M)
RANGE_RE = re.compile(r"^Range ([0-9a-f]{7,40})\.\.([0-9a-f]{7,40})$", re.M)

REVIEW_PROMPT = """You are the pre-landing code reviewer for this repository.
Review the diff below against these rules. Look for a real defect, a scope
violation or a security problem that this diff introduces.

--- RULES ---
{rules}
--- DIFF ---
{diff}
--- END ---

Finish with exactly one line: `Verdict: flag` if the diff has an Important
finding that should block landing, else `Verdict: pass`."""


def git(repo, *args, check=True):
    r = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout


def write_case(corpus, case, diff, fix=None):
    d = pathlib.Path(corpus) / "cases" / case["id"]
    if d.exists():
        return False
    if not diff.strip():
        print(f"skip {case['id']}: empty diff", file=sys.stderr)
        return False
    d.mkdir(parents=True)
    (d / "diff.patch").write_text(diff)
    if fix:
        (d / "fix.patch").write_text(fix)
    (d / "case.json").write_text(json.dumps(case, indent=2) + "\n")
    return True


def cmd_harvest(a):
    repo = a.repo
    ref = a.ref
    if not ref:
        has_origin = subprocess.run(["git", "-C", repo, "rev-parse", "-q", "--verify", "origin/master"],
                                    capture_output=True).returncode == 0
        ref = "origin/master" if has_origin else "HEAD"
    fmt = "%H%x1f%(trailers:key=Autocoder-Reverts,valueonly,separator=%x20)%x1f" \
          "%(trailers:key=Autocoder-Reverts-Issue,valueonly,separator=%x20)%x1e"
    added = 0
    for rec in git(repo, "log", ref, f"--format={fmt}").split("\x1e"):
        parts = rec.strip("\n").split("\x1f")
        if len(parts) < 3 or not parts[1].strip():
            continue
        revert, culprit, issue = parts[0].strip(), parts[1].strip(), parts[2].strip()
        m = RANGE_RE.search(git(repo, "log", "-1", "--format=%B", revert))
        if not m or not culprit.startswith(m.group(2)[:7]):
            print(f"skip revert {revert[:7]}: no Range line matching culprit {culprit[:7]}", file=sys.stderr)
            continue
        prev_good = m.group(1)
        diff = git(repo, "diff", "--binary", prev_good, culprit)
        # The re-land: a later commit on REF that reverted the sentinel's revert
        # (`git revert <revert>`, as reland_howto() tells the human to do). That
        # commit only re-applies the culprit; the fix is in the issue's own commits
        # after it.
        reland = git(repo, "log", "--format=%H", "--reverse", f"--grep=This reverts commit {revert}",
                     f"{revert}..{ref}").split()
        fix = None
        if reland and issue.isdigit():
            fix_commits = git(repo, "log", "--format=%H", "--reverse", "--no-merges", "-E",
                              f"--grep=^(Fix )?#{issue}([^0-9]|$)", f"{reland[0]}..{ref}").split()
            fix = "".join(git(repo, "show", "--format=commit %H%n%n    %s%n", "--binary", c)
                          for c in fix_commits) or None
        case = {
            "id": f"revert-{culprit[:10]}",
            "kind": "culprit", "expect": "flag", "source": "sentinel-revert",
            "issue": issue or None,
            "commits": {"prev_good": prev_good, "culprit": culprit, "revert": revert,
                        "reland": reland[0] if reland else None},
            "note": "Reverted by the post-merge sentinel: the regression gate went red on this push.",
        }
        if write_case(a.corpus, case, diff, fix):
            added += 1
            print(f"added {case['id']} (issue {issue or '?'})")
    print(f"harvest: {added} new culprit case(s) from {ref}")
    return 0


def cmd_add(a):
    sha = git(a.repo, "rev-parse", "--verify", (a.clean or a.reversed_fix) + "^{commit}").strip()
    subject = git(a.repo, "log", "-1", "--format=%s", sha).strip()
    if a.clean:
        diff = git(a.repo, "show", "--format=", "--binary", sha)
        fix = None
        case = {"id": f"clean-{sha[:10]}", "kind": "clean", "expect": "pass", "source": "landed-clean",
                "issue": None, "commits": {"commit": sha}, "note": a.note or subject}
    else:
        parents = git(a.repo, "log", "-1", "--format=%P", sha).split()
        if len(parents) != 1:
            print(f"review-corpus: {sha[:7]} is not a single-parent commit", file=sys.stderr)
            return 2
        diff = git(a.repo, "diff", "--binary", sha, parents[0])
        fix = git(a.repo, "show", "--format=", "--binary", sha)
        case = {"id": f"reversed-fix-{sha[:10]}", "kind": "culprit", "expect": "flag",
                "source": "reversed-fix", "issue": None, "commits": {"fix": sha},
                "note": a.note or f"Reverse of the fix: {subject}"}
    if write_case(a.corpus, case, diff, fix):
        print(f"added {case['id']}")
        return 0
    print(f"review-corpus: {case['id']} exists or has an empty diff", file=sys.stderr)
    return 1


def run_reviewer(reviewer, case_dir, diff, rules):
    env = dict(os.environ, REVIEW_CASE_DIR=str(case_dir), REVIEW_RULES=str(rules))
    if reviewer == "claude":
        rules_text = pathlib.Path(rules).read_text()
        cmd = ["claude", "-p", "--model", os.environ.get("REVIEW_MODEL", "sonnet")]
        stdin = REVIEW_PROMPT.format(rules=rules_text, diff=diff)
    else:
        cmd = shlex.split(reviewer)
        stdin = diff
    try:
        r = subprocess.run(cmd, input=stdin, capture_output=True, text=True, env=env,
                           timeout=int(os.environ.get("REVIEW_TIMEOUT", "600")))
    except (OSError, subprocess.TimeoutExpired) as e:
        return "error", str(e)
    found = VERDICT_RE.findall(r.stdout)
    if not found:
        return "error", f"no Verdict line (exit {r.returncode})"
    return found[-1].lower(), ""


def cmd_score(a):
    cases_dir = pathlib.Path(a.corpus) / "cases"
    cases = sorted(cases_dir.glob("*/case.json")) if cases_dir.is_dir() else []
    if not cases:
        print(f"review-corpus: no cases under {cases_dir}", file=sys.stderr)
        return 1
    if a.reviewer == "claude" and not pathlib.Path(a.rules).is_file():
        print(f"review-corpus: no rules file at {a.rules} (pass --rules or --repo)", file=sys.stderr)
        return 1
    rows = []
    for cj in cases:
        try:
            case = json.loads(cj.read_text())
            kind, expect, cid = case["kind"], case["expect"], case["id"]
            diff = (cj.parent / "diff.patch").read_text()
        except (OSError, ValueError, KeyError) as e:
            print(f"review-corpus: malformed case {cj.parent.name}: {e}", file=sys.stderr)
            return 1
        verdict, err = run_reviewer(a.reviewer, cj.parent, diff, a.rules)
        rows.append({"id": cid, "kind": kind, "expect": expect,
                     "verdict": verdict, "correct": verdict == expect, "error": err or None})
    culprits = [r for r in rows if r["kind"] == "culprit"]
    clean = [r for r in rows if r["kind"] == "clean"]
    if not culprits or not clean:
        print("review-corpus: the corpus needs both culprit and clean cases to score", file=sys.stderr)
        return 1
    # An error is wrong for either kind: never a catch, always a false alarm.
    caught = sum(r["verdict"] == "flag" for r in culprits)
    alarms = sum(r["verdict"] != "pass" for r in clean)
    catch_rate = caught / len(culprits)
    alarm_rate = alarms / len(clean)
    score = catch_rate - alarm_rate
    result = {"cases": len(rows), "culprits": len(culprits), "caught": caught,
              "clean": len(clean), "false_alarms": alarms,
              "errors": sum(r["verdict"] == "error" for r in rows),
              "catch_rate": catch_rate, "false_alarm_rate": alarm_rate,
              "score": round(score, 4), "reviewer": a.reviewer, "rows": rows}

    if a.json:
        print(json.dumps(result, indent=2))
    else:
        for r in rows:
            mark = "ok " if r["correct"] else "BAD"
            extra = f"  ({r['error']})" if r["error"] else ""
            print(f"{mark} {r['id']:<32} {r['kind']:<8} expect {r['expect']:<4} got {r['verdict']}{extra}")
        fmt = lambda x: f"{x:.0%}"
        print(f"\ncaught {caught}/{len(culprits)} ({fmt(catch_rate)}), false alarms {alarms}/{len(clean)} "
              f"({fmt(alarm_rate)}), errors {result['errors']}, score {result['score']}")

    if result["errors"]:
        print(f"review-corpus: {result['errors']} case(s) got no verdict; the score is not trustworthy",
              file=sys.stderr)
        return 1
    if a.save:
        pathlib.Path(a.save).write_text(json.dumps({k: v for k, v in result.items() if k != "rows"}, indent=2) + "\n")
    if a.baseline:
        base = json.loads(pathlib.Path(a.baseline).read_text())["score"]
        better = score > base or (a.allow_equal and score == base)
        print(f"baseline {base} → {result['score']}: {'improved' if score > base else 'no improvement' if score == base else 'WORSE'}",
              file=sys.stderr)
        return 0 if better else 1
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--corpus", default=DEFAULT_CORPUS)
    p.add_argument("--repo", default=".")
    sub = p.add_subparsers(dest="cmd", required=True)
    h = sub.add_parser("harvest")
    h.add_argument("--ref")
    ad = sub.add_parser("add")
    g = ad.add_mutually_exclusive_group(required=True)
    g.add_argument("--clean", metavar="SHA")
    g.add_argument("--reversed-fix", metavar="SHA")
    ad.add_argument("--note")
    s = sub.add_parser("score")
    s.add_argument("--reviewer", default="claude")
    s.add_argument("--rules", default="REVIEW.md")
    s.add_argument("--json", action="store_true")
    s.add_argument("--baseline")
    s.add_argument("--allow-equal", action="store_true")
    s.add_argument("--save")
    # Accept the global options after the subcommand too.
    for sp in (h, ad, s):
        sp.add_argument("--corpus", default=argparse.SUPPRESS)
        sp.add_argument("--repo", default=argparse.SUPPRESS)
    a = p.parse_args()
    repo = pathlib.Path(a.repo)
    a.corpus = str(repo / a.corpus)
    if getattr(a, "rules", None):
        a.rules = str(repo / a.rules)
    try:
        return {"harvest": cmd_harvest, "add": cmd_add, "score": cmd_score}[a.cmd](a)
    except RuntimeError as e:
        print(f"review-corpus: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
