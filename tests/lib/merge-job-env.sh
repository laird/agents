# tests/lib/merge-job-env.sh — drop the merge job's context variables (#327).
# Sourced by tests/run-shell-suite.sh and tests/lib/private-event-logs.sh.
#
# The merge gate runs this suite inside merge-to-integration.sh, which exports
# variables meant for its own gate command: the files to re-run on a red base, the
# repository and train its ledger rows name, its per-run stage-timings file, its
# scripts snapshot and attempt number. Many tests run merge-to-integration.sh (or
# the gate-cache functions) themselves; inheriting the outer job's values made them
# test a different run than they set up. AUTOCODER_GATE_RETEST_FILES changes every
# gate-cache key, and AUTOCODER_LANDING_REPO renames every ledger row. So master
# was red only inside the merge job, never in CI or by hand.
#
# A test that needs one of these sets it itself after sourcing the prelude.
unset AUTOCODER_GATE_RETEST_FILES \
      AUTOCODER_LANDING_REPO AUTOCODER_LANDING_BATCH AUTOCODER_LANDING_MEMBERS \
      AUTOCODER_STAGE_TIMINGS_FILE AUTOCODER_SCRIPTS_DIR AUTOCODER_MERGE_ATTEMPT
