# Spot-Check Merged Work

Review the sample of merge-mode work the swarm set aside for a human (#197). Uses the
configured issue source.

In `merge` mode the swarm lands work and closes the issue without a person ever
reading the change. When the merge job closes an issue it runs
`spot-check-select.sh`, which labels some of that work `spot-check`:

| Reason | Selected when |
|---|---|
| `P0` / `P1` | the issue is P0 or P1 |
| `security` | a changed path matches `.autocoder.json` `spotCheck.securityPaths`, or the issue has the `security` label |
| `size` | the diff is over the review-fit thresholds (`reviewFit.maxChangedLines` / `reviewFit.maxFiles`, mirrors excluded) |
| `sampled` | a random sample at `spotCheck.rate` (default `0.10`), decided by a hash of the landed commit |

Selection never blocks the merge: the issue is closed as usual. This command is where
the sampled items get read.

## Usage

```bash
/spot-check            # walk every unreviewed item, oldest first
/spot-check 212        # review one item
```

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
  find "$HOME/.claude/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" -not -path "*/skills/*" 2>/dev/null \
    | while read -r d; do if [ -f "$d/issue-fns.sh" ] && [ -f "$d/fix-loop-gate.sh" ]; then echo "$d"; fi; done \
    | awk -F/ '{print $(NF-1) "\t" $0}' | sort -V -t$'\t' -k1,1 | tail -1 | cut -f2-
)
if [ ! -f "${SCRIPT_DIR}/issue-fns.sh" ]; then
  echo "autocoder: cannot locate issue-fns.sh (resolved SCRIPT_DIR='${SCRIPT_DIR}')" >&2
  exit 1
fi
source "${SCRIPT_DIR}/issue-fns.sh"

# Spot-check items are CLOSED by design, so --state open would find none.
issue_list --state all --label spot-check --limit 500 \
  | jq -r 'sort_by(.number) | .[] | "#\(.number)\t\(.state)\t\(.title)"'
```

If a number was given, review only that item. Otherwise take the items in the order
listed. For each item:

1. **Show it.** Print the close comment (the review digest: intent, where to look,
   verification, confidence) and the spot-check comment, which names the commit:

   ```bash
   N=<item>
   issue_get "$N" | jq -r '.comments[]?.body | select(test("Issue Resolved|Complex Issue Resolved|Spot-check selected"))'
   SHA=$(issue_get "$N" | jq -r '[.comments[]?.body | capture("Spot-check selected.*git show (?<sha>[0-9a-f]+)")?.sha] | last // empty')
   git fetch -q origin && git show --stat "$SHA" && git show "$SHA"
   ```

   For a merge commit, `git show "$SHA"` shows a combined diff that is often empty; use
   `git diff "$SHA^1" "$SHA"` to see the change it landed.

2. **Read it with the human** and ask for one outcome:
   - **ok**: the change is fine.
   - **follow-up**: the change works but needs more work (a bug, a refactor, a missing
     test). Create a linked issue.
   - **revert**: the approach is wrong. Create a P1 issue to revert or rework it, linked
     to the commit.

3. **Record the outcome** as a comment, then remove the label. The comment format is
   fixed so `/retro` can count follow-up and revert rates:

   ```bash
   # ok
   issue_comment "$N" --body "🔎 Spot-check: ok"

   # follow-up
   NEW=$(issue_create --label P2 --title "Follow-up to #$N: <what needs doing>" \
     --body "Spot-check of #$N (commit \`$SHA\`) found: <finding>.

   Follow-up to #$N." | jq -r '.number')
   issue_comment "$N" --body "🔎 Spot-check: follow-up #$NEW"

   # revert
   NEW=$(issue_create --label P1 --label bug --title "Revert or rework #$N: <why>" \
     --body "Spot-check of #$N found the approach is wrong: <finding>.

   Commit to revert or rework: \`$SHA\` (\`git revert -m 1 $SHA\` for a merge commit)." | jq -r '.number')
   issue_comment "$N" --body "🔎 Spot-check: revert #$NEW"

   # every outcome
   issue_update "$N" --remove-label spot-check
   ```

   Write the finding into the new issue in your own words; the `<…>` parts above are
   for you to fill, never to post as they are. The reviewed issue stays closed.

When no items are left, say so and stop.

## Settings

`.autocoder.json` in the primary checkout (or, if the file is tracked, the copy on the
integration side of the landed change). It is never read from the change under review,
so a change cannot switch off its own sampling:

```json
{
  "spotCheck": {
    "rate": 0.10,
    "securityPaths": [".github/workflows/*", "plugins/autocoder/scripts/*push*"],
    "backlogMax": 20
  }
}
```

- `rate`: share of other merged work sampled, 0 to 1. `AUTOCODER_SPOT_CHECK_RATE`
  overrides it.
- `securityPaths`: globs for paths that always select. A glob matches the whole path
  and `*` also matches `/`, so write `auth/*`, not `auth/`. Empty by default.
- `backlogMax`: `/monitor-workers` warns when more items than this are unreviewed. It
  never pauses the swarm.

`pr` mode does not use spot-check: a human already reviews each PR.
