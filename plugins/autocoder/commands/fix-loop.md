# /fix-loop — renamed to /dev-loop

`/fix-loop` was renamed to `/dev-loop` (the loop both fixes bugs and implements features).

Run `/autocoder:dev-loop` with the same arguments you passed here — this alias forwards
to `/dev-loop` and is kept only for convenience. Prefer `/dev-loop` directly; internal
callers (gate, dispatch, worker launch) already use the new name.
