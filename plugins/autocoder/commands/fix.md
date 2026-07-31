# /fix — renamed to /dev

`/fix` was renamed to `/dev` (the loop both fixes bugs and implements features).

Run `/autocoder:dev` with the same arguments you passed here — this alias forwards
to `/dev` and is kept only for convenience. Prefer `/dev` directly; internal
callers (gate, dispatch, worker launch) already use the new name.
