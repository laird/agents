#!/usr/bin/env bash
# release.sh — cut a GitHub Release and record it as a GitHub Deployment to the
# `release` environment, so whatever reads Deployments sees what was released.
#
# USAGE:
#   release.sh [<tag>] [--commit <sha|ref>] [--dry-run] [--integration <branch>]
#   release.sh --next-tag
#
#   <tag>          the release tag. Without one it is the next tag of the scheme:
#                  date (default)  vYYYY.MM.DD.N, N is 1 for the day's first release
#                                  and counts up, from the tags already on origin
#                  semver          vX.Y.Z with Z one past the newest vX.Y.Z on origin
#                                  (v0.1.0 when there is none)
#   --commit       what to release (default: origin/<integration>); must be on it
#   --dry-run      run every check and print the tag and commit it would release;
#                  create nothing
#   --next-tag     print the tag the next release would get, and nothing else
#   --integration  the integration branch (default: origin/HEAD, else main)
#
# CONFIG (.autocoder.json in the main worktree, all optional):
#   "tagScheme": "date" | "semver"         default date
#   "releaseEnvironment": "release"        the Deployment environment a release is recorded to
#
# A commit that already is the newest release (of the scheme) is not released again:
# it says so and exits 0. deploy.sh releases each deploy this way, and the pre-push
# hook (install-hooks.sh) each push of the integration branch from the main checkout.
#
# Releasing a tag that already has a GitHub Release only records the deployment,
# so a release made by hand can be recorded afterwards. The Deployment's
# description is "Release <tag>" and its status's log_url the Release's page.
#
# RELEASE_DATE (YYYY.MM.DD) overrides today's date, for tests.
#
# Portable to macOS: bash 3.2, BSD sort, date and sed.
#
# EXIT: 0 released, already released, or dry run passed · 1 refused or setup error
set -euo pipefail

TAG=""
COMMIT=""
DRY_RUN=false
NEXT_ONLY=false
INTEGRATION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --commit|--integration) [ $# -ge 2 ] || { echo "release.sh: $1 needs a value" >&2; exit 1; } ;;
  esac
  case "$1" in
    --commit) COMMIT="$2"; shift 2 ;;
    --integration) INTEGRATION="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --next-tag) NEXT_ONLY=true; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*) echo "release.sh: unknown argument: $1" >&2; exit 1 ;;
    *) [ -z "$TAG" ] || { echo "release.sh: one tag only" >&2; exit 1; }; TAG="$1"; shift ;;
  esac
done

say() { echo "release.sh: $*"; }
refuse() { echo "release.sh: refusing: $*" >&2; exit 1; }
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || refuse "not inside a git checkout"
cd "$TOP"

if [ -z "$INTEGRATION" ]; then
  INTEGRATION=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)
  INTEGRATION="${INTEGRATION:-main}"
fi

MAIN_WT=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p' || true)
CONFIG="${AUTOCODER_CONFIG:-${MAIN_WT:-$TOP}/.autocoder.json}"
release_settings() {
  python3 - "$CONFIG" <<'PY' 2>/dev/null || echo "date release"
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    data = {}
data = data if isinstance(data, dict) else {}
scheme = str(data.get("tagScheme") or "date").strip().lower()
env = str(data.get("releaseEnvironment") or "release").strip() or "release"
print(scheme, env.replace(" ", "-"))
PY
}
SETTINGS=$(release_settings)
SCHEME=${SETTINGS%% *}
RELEASE_ENV=${SETTINGS#* }
case "$SCHEME" in
  date) PATTERN='^v[0-9][0-9][0-9][0-9][.][0-9][0-9][.][0-9][0-9][.][0-9]+$' ;;
  semver) PATTERN='^v[0-9]+[.][0-9]+[.][0-9]+$' ;;
  *) refuse "unknown tagScheme '$SCHEME' in $CONFIG (date or semver)" ;;
esac

# Tags on origin as "<commit> <tag>", annotated tags peeled to their commit.
origin_tags() {
  git ls-remote --tags origin 'v*' 2>/dev/null | awk '
    { sub("refs/tags/", "", $2) }
    $2 ~ /\^\{\}$/ { sub(/\^\{\}$/, "", $2); peeled[$2] = $1; next }
    { plain[$2] = $1 }
    END { for (t in plain) print (t in peeled ? peeled[t] : plain[t]), t }'
}
# newest_tag, with tag names on stdin: the highest, comparing the numbers
# between the dots (v2026.11.09.10 is after v2026.11.09.9). Not `sort -V`:
# macOS's older sort has no -V.
newest_tag() {
  awk 'function newer(t,   x, y, n, m, i, a, b) {
         x = t; y = best; sub(/^v/, "", x); sub(/^v/, "", y)
         n = split(x, a, "."); m = split(y, b, ".")
         for (i = 1; i <= n || i <= m; i++) {
           if (i > m) return 1
           if (i > n) return 0
           if (a[i] + 0 != b[i] + 0) return a[i] + 0 > b[i] + 0
         }
         return 0
       }
       NF && (best == "" || newer($0)) { best = $0 }
       END { if (best != "") print best }'
}
# next_tag, with the scheme's tag names on stdin.
next_tag() {
  if [ "$SCHEME" = semver ]; then
    newest_tag | awk '{ sub(/^v/, ""); split($0, a, "."); print "v" a[1] "." a[2] "." (a[3] + 1); found = 1 }
      END { if (!found) print "v0.1.0" }'
  else
    awk -v p="v$DAY." 'index($0, p) == 1 { n = substr($0, length(p) + 1); if (n ~ /^[0-9]+$/ && n + 0 > max) max = n + 0 }
      END { print p (max + 1) }'
  fi
}
DAY="${RELEASE_DATE:-$(date +%Y.%m.%d)}"
# Only the scheme's own tags count: a v1.3.0-rc1 or a stray vfoo is not a release.
TAGS=$(origin_tags | awk -v re="$PATTERN" '$2 ~ re')
tag_names() { [ -z "$TAGS" ] || awk '{ print $2 }' <<< "$TAGS"; }
if [ "$NEXT_ONLY" = true ]; then
  tag_names | next_tag
  exit 0
fi

git fetch --quiet --tags origin "+refs/heads/$INTEGRATION:refs/remotes/origin/$INTEGRATION" \
  || refuse "cannot fetch origin/$INTEGRATION"

# No tag given: release only what isn't released yet, under the next tag.
AUTO=false
if [ -z "$TAG" ]; then
  SHA=$(git rev-parse "${COMMIT:-origin/$INTEGRATION}^{commit}" 2>/dev/null) || refuse "unknown commit: ${COMMIT}"
  NEWEST=$(tag_names | newest_tag)
  NEWEST_SHA=$(awk -v t="$NEWEST" '$2 == t { print $1 }' <<< "$TAGS")
  if [ -n "$NEWEST" ] && [ "$NEWEST_SHA" = "$SHA" ]; then
    say "${SHA:0:12} is already the newest release ($NEWEST); not releasing it again"
    exit 0
  fi
  TAG=$(tag_names | next_tag)
  COMMIT="$SHA"
  AUTO=true
fi

EXISTS=false
# A tag just made up from origin's tags: no release can have it yet.
if [ "$AUTO" != true ] && gh release view "$TAG" >/dev/null 2>&1; then
  EXISTS=true
  # An existing release names its own commit.
  SHA=$(gh api "repos/{owner}/{repo}/commits/$TAG" --jq .sha) || refuse "cannot resolve the commit of release $TAG"
  [ -z "$COMMIT" ] || [ "$(git rev-parse "$COMMIT^{commit}")" = "$SHA" ] \
    || refuse "release $TAG already exists at ${SHA:0:12}, not at $COMMIT"
else
  SHA=$(git rev-parse "${COMMIT:-origin/$INTEGRATION}^{commit}" 2>/dev/null) || refuse "unknown commit: ${COMMIT}"
fi
git merge-base --is-ancestor "$SHA" "origin/$INTEGRATION" \
  || refuse "${SHA:0:12} is not on origin/$INTEGRATION; only landed work is released"

say "tag:    $TAG $([ "$EXISTS" = true ] && echo '(release exists)')"
say "commit: $SHA ($(git log -1 --format=%s "$SHA" 2>/dev/null || echo 'not fetched'))"

if [ "$DRY_RUN" = true ]; then
  [ "$EXISTS" = true ] || say "dry run: would run: gh release create $TAG --target $SHA --generate-notes"
  say "dry run: would record a Deployment of ${SHA:0:12} to '$RELEASE_ENV'"
  say "dry run: checks passed, nothing changed"
  exit 0
fi

if [ "$EXISTS" = false ]; then
  gh release create "$TAG" --target "$SHA" --generate-notes || refuse "gh release create failed"
fi
URL=$(gh release view "$TAG" --json url --jq .url 2>/dev/null || echo "")
ID=$(gh api "repos/{owner}/{repo}/deployments" \
  -f ref="$SHA" -f environment="$RELEASE_ENV" -f description="Release $TAG" \
  -F auto_merge=false -F 'required_contexts[]' --jq .id) || refuse "GitHub would not create the deployment"
gh api "repos/{owner}/{repo}/deployments/$ID/statuses" \
  -f state=success -f description="Release $TAG" ${URL:+-f log_url="$URL"} >/dev/null \
  || refuse "deployment $ID was created but could not be marked success"
say "released $TAG (${SHA:0:12}) and recorded deployment $ID to $RELEASE_ENV"
