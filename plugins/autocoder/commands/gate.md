<!--
Slim fix-loop gate. Per spec §5.3 / §7.1.1, no `model:` frontmatter:
inherits the model from whatever invokes it (fix-loop's loop model).
A Haiku-pinned variant (`/autocoder:dispatch`) is Phase 3, not here.
-->

# Fix-Loop Gate

Pre-LLM gate that decides whether the tick has work. Idle: cheap exit. Work: dispatch.

> **MANDATORY — no inter-session messaging:** Do NOT use `SendMessage` (or any tool that contacts another session) at any point in this command — not at startup, not when idle, not after completing work. Silent execution is the correct behavior. The ONLY exception is a genuine blocker the manager must resolve before you can continue.

## Instructions

```bash
# Resolve SCRIPT_DIR — see scripts/README.md#script-dir
SCRIPT_DIR=$(
  for d in "$(pwd)/.agent/scripts" \
           "$(pwd)/plugins/autocoder/scripts" \
           "$(pwd)/.claude-plugin/plugins/autocoder/scripts"; do
    if [ -f "$d/issue-fns.sh" ] && [ -f "$d/fix-loop-gate.sh" ]; then echo "$d"; exit 0; fi
  done
  # Fallback: the installed plugin. Only <ver>/scripts is a complete tree;
  # <ver>/skills/autocoder/scripts is a subset that sorts after it (#142).
  # Rank by the <ver> directory alone, not the whole path: with two marketplaces
  # in the cache, a whole-path sort lets the marketplace name decide (#201).
  found=$(
  find "$HOME/.claude/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" -not -path "*/skills/*" 2>/dev/null \
    | while read -r d; do if [ -f "$d/issue-fns.sh" ] && [ -f "$d/fix-loop-gate.sh" ]; then echo "$d"; fi; done \
    | awk -F/ '{print $(NF-1) "\t" $0}' | sort -V -t$'\t' -k1,1 | tail -1 | cut -f2-
  )
  if [ -n "$found" ]; then echo "$found"; exit 0; fi
  # Grok installs to ~/.grok/installed-plugins/<name>-<hash>/. The hash is in
  # the directory name, so the Claude cache glob */autocoder/* does not match.
  find "$HOME/.grok/installed-plugins" -type d -name "scripts" -path "*/autocoder-*/*" -not -path "*/skills/*" 2>/dev/null \
    | while read -r d; do if [ -f "$d/issue-fns.sh" ] && [ -f "$d/fix-loop-gate.sh" ]; then echo "$d"; fi; done \
    | awk -F/ '{print $(NF-1) "\t" $0}' | sort -V -t$'\t' -k1,1 | tail -1 | cut -f2-
)
if [ ! -f "${SCRIPT_DIR}/issue-fns.sh" ]; then
  echo "autocoder: cannot locate issue-fns.sh (resolved SCRIPT_DIR='${SCRIPT_DIR}')" >&2
  exit 1
fi
source "${SCRIPT_DIR}/issue-fns.sh"
WORK_JSON="${AUTOCODER_WORK_JSON:-/tmp/autocoder-work.json}"
bash "$SCRIPT_DIR/fix-loop-gate.sh"; GATE_RC=$?
```

Branch on `$GATE_RC`:

- **1 (idle):** emit exactly `IDLE_NO_WORK_AVAILABLE` and stop. No further tool calls. Do NOT use `SendMessage` or any other tool to notify another session of your idle status — silent stop is correct.
- **2 (config error):** emit `GATE_CONFIG_ERROR` and stop.
- **0 (work):** `PHASE=$(jq -r .phase "$WORK_JSON")` then act:

### phase = `triage`

For each `N` in `.issues[]`: read body via `issue_view N`, apply matrix, then:

```bash
issue_update N --add-label "<P0|P1|P2|P3>"
issue_comment N "Triage: <priority> — <one-line rationale>"
```

| Indicator | P0 | P1 | P2 | P3 |
|---|---|---|---|---|
| Impact | Down | Major | Partial | Minimal |
| Scope | All | Many | Some | Few |
| Workaround | None | Hard | Yes | Easy |
| Data risk | Loss | Possible | Unlikely | None |
| Security | Exploit | Vuln | Potential | None |
| Keywords | crash/down/urgent/security | broken/fails/blocking | issue/bug | minor/cosmetic |

Keep terse. Do not load `/autocoder:fix`. Stop after all triaged.

### phase = `fix` or `enhance`

**`"in_flight": true`: this session already holds the issue (#130).** In inline `/loop`
mode a tick can fire while this very session is mid-issue. The gate recognises its own
session and does not claim new work or touch the checkout. **Never invoke
`/autocoder:fix` and never write a handoff file for an in-flight issue**: `/fix`'s claim
steps are already done, and re-running them can race the work in progress. Decide which
case applies by checking, not by recollection:

1. **Is anything for this issue still running?** Check each of these:
   - a merge job: run `merge-poll.sh --issue <issue>` from this checkout (it waits about
     60 s). Exit **75** means a job is running. Any other exit means none is running
     here;
   - a background agent or task you started for it that has not reported back;
   - a test or build you started in the background.

   **If any is running:** emit `IN_FLIGHT_CONTINUING #<issue>` and stop the tick. The
   next tick checks again.
2. **If none is running:** the work was interrupted, abandoned or forgotten, perhaps
   after a compaction. The gate reports `in_flight` only while the issue is open and
   still `working`; a merge job's hand-off swaps that label away, so a handed-off issue
   never reaches this step. Before touching anything, confirm it is still open and
   `working` (`issue_get <issue>`). If it is not, stop. Then pick it up in this session:
   - if the tree is not on `feature/issue-<issue>`, switch only when `git status` shows no
     tracked changes; otherwise stop and report the dirty tree instead;
   - re-read the issue's comments and `git log origin/<integration>..HEAD`;
   - carry on with the remaining steps (implement, test, review, land) as `/fix`
     describes them, without re-running its claim sequence.

   A held issue must not sit idle, or it stays `working` with nobody on it.

A plan with `"dispatched": true` is a **manager's dispatch** (`dispatch-issue.sh`, a file the
gate takes ahead of its own pick, ahead of triage, and ahead of an idle exit): the issue is
already claimed, or resumed when it was this worktree's own held claim (then `"resume": true`
too). Dispatch it like any other plan; nothing about the claim steps changes.

A plan with `"resume": true` and `"in_flight": false` is **this worktree's own claim,
picked up by a new session** (#182): a restart or a fresh worker process found an open
`working` issue recorded for this worktree and resumes it before claiming anything new.
That includes an issue a merge job bounced back to this worktree (#208): a conflict or a
red gate its change caused, named in a `<!-- autocoder-bounce ... worktree=<this worktree> -->`
comment. For a bounce, rebase onto the integration branch, resolve the conflicts or
failing tests, re-test, re-review and relaunch the merge.
Dispatch it the same way. `/fix N` recognises the resume and skips its race check.
Re-read the issue's comments and the branch's commits before continuing, so finished
work is not redone.

Each issue must run in a **fresh Claude process** for a clean context window. The mechanism
depends on how the gate was invoked:

**Shell-loop mode** (when `AUTOCODER_NEXT_FIX_FILE` env var is set — i.e., running under
`claude-worker-loop.sh`): write the issue number to the handoff file and exit. The shell wrapper
will start a new `claude` process for fix automatically.

```bash
ISSUE_NUM=$(jq -r .issue "$WORK_JSON")
if [ -n "${AUTOCODER_NEXT_FIX_FILE:-}" ]; then
  echo "$ISSUE_NUM" > "$AUTOCODER_NEXT_FIX_FILE"
  exit 0
fi
```

**Inline mode** (fallback when gate is invoked standalone or via `/loop`): dispatch via Skill
tool in the current session. Context will accumulate across issues in this mode — prefer
shell-loop mode for multi-issue worker sessions.

```
Use the Skill tool to invoke: autocoder:fix
With args: <issue number from work JSON>
```

**A branch on origin is a claim (athena2#7185).** The gate does not claim an issue that a branch on
origin names, and does not take over a `working` issue that has one. `issue-<N>` anywhere in the branch
name counts, and so do `hotfix/<N>-<slug>` and `hotfix/<N>`.

**Declining the issue (#248).** By the time you read the work plan, the gate has already
**claimed** the issue: it carries `working` and a `🔒 claim` comment naming this worker.
If you will not dispatch it this tick, for any reason (most often because you must
compact your context before starting a new issue), give the claim back **before you
stop**. Otherwise nobody works the issue and every other worker stays off it:

```bash
bash "$SCRIPT_DIR/release-gate-claim.sh" "$(jq -r .issue "$WORK_JSON")" "<why this tick declined it, e.g. holding for context compaction>"
```

Then emit `GATE_CLAIM_RELEASED #<issue>` and stop. The script releases only a claim this
worktree's gate recorded, and refuses once `feature/issue-<N>` exists in this checkout (work
has started: use `/fix`'s explicit release then) or once another worker has claimed the issue
since. A `feature/issue-<N>` on origin alone is another worker's and does not stop the release.
A `"resume": true` plan whose branch does not exist yet may be released the same way. Never
run it for an `"in_flight": true` plan, which is work this session already has under way.
