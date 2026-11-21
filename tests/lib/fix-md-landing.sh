#!/bin/bash
# tests/lib/fix-md-landing.sh: fix.md lands every flow through one section (#242).
#
# Step 2A, Step 3 and 5D each commit, set LAND_NUM/LAND_BRANCH/LAND_TITLE/LAND_BODY,
# and end at "### Landing the Work". Tests that pin a landing site's parts (push,
# landing mode, review digest, merge launch, PR) count them once, in that section,
# and call fix_md_landing_problems to check that all three flows reach it.

# fix_md_landing_problems <fix.md>: one line per problem; prints nothing when
# there is exactly one landing section, each flow sets the landing variables for
# its own issue and branch, and no push, merge launch or PR happens outside it.
fix_md_landing_problems() {
  awk '
    /^```/ { fence = !fence; next }
    !fence && /^#+ / {
      sec = ""
      if ($0 ~ /^### Step 2A:/) sec = "2A"
      else if ($0 ~ /^### Step 3: Commit and Close/) sec = "3"
      else if ($0 ~ /^#### 5D:/) sec = "5D"
      else if ($0 ~ /^### Landing the Work/) { sec = "land"; lands++ }
    }
    sec == "2A" || sec == "3" {
      if (index($0, "LAND_NUM=\"$ISSUE_NUM\"; LAND_BRANCH=\"feature/issue-${ISSUE_NUM}\"; LAND_TITLE=\"$ISSUE_TITLE\"; LAND_BODY=\"$ISSUE_BODY\"")) set[sec]++
    }
    sec == "5D" {
      if (index($0, "LAND_NUM=\"$ENHANCE_NUM\"; LAND_BRANCH=\"enhancement/issue-${ENHANCE_NUM}-auto\"; LAND_TITLE=\"$ENHANCE_TITLE\"; LAND_BODY=\"$ENHANCE_BODY\"")) set[sec]++
    }
    sec != "land" && /git push -u origin "|merge-launch\.sh" *\\?$|^ *gh pr create|^ *LANDING_MODE=\$\(bash/ {
      print "landing step outside the landing section at line " NR ": " $0
    }
    END {
      if (lands != 1) print "want exactly one \"### Landing the Work\" section, found " lands + 0
      if (set["2A"] != 1) print "Step 2A does not set the landing variables for its issue exactly once"
      if (set["3"] != 1) print "Step 3 does not set the landing variables for its issue exactly once"
      if (set["5D"] != 1) print "5D does not set the landing variables for its enhancement exactly once"
    }
  ' "$1"
}
