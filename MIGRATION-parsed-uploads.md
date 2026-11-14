# Moving replay reading from the server to the Windows uploader

**What changed.** The uploader (1.2.0) reads each `.rec` on the PC with the bundled `r6-dissect.exe` and sends about 3 KB of
JSON to `POST /v1/parsed`, instead of the 6 to 12 MB file. The server validates it, stores it as it stored parsed rounds
before, and the Android app is unchanged (it reads the same fields). Scoring, the baseline and the advice were never on
the server; they run in the phone app.

## Rollout order
1. **Server first (done).** `POST /v1/parsed` is live. `R6_MIN_PARSER` is `0.0.0`, so no uploader is refused. The raw
   routes (`/v1/upload`, `/v1/upload/raw`) still work and answer with `Deprecation: true`. `/v1/known` still returns
   `known` unchanged and now also `failed`.
2. **Then the uploader.** Ship 1.2.0 (Windows 10+). It uses `/v1/parsed` when `/health` says `"parsed": true`, otherwise
   it sends whole files like before. On Windows 7/8 the reader cannot start; the app notices and sends whole files.
   Version 1.1.0 stays on the website for those systems.
3. **Deprecate the raw routes** when the server log shows no raw uploads from current versions for a few weeks. Only then
   remove them. Until then they are also the fallback for replays a PC cannot read.

## After a game patch (a new operator or map)
Rounds from the new content fail to read: the log says `role unknown for operator ID …`. To fix:
1. Rebuild the reader from the newest r6-dissect (`GOOS=windows GOARCH=amd64 go build -ldflags "-s -w"`) with
   `pc-app/third_party/r6-dissect-unknown-operators.patch` if it still applies; copy the binary to
   `pc-app/third_party/r6-dissect.exe` and the Linux build to the server (`/opt/r6-replay-server/bin/r6-dissect`).
2. Bump `kParserVersion` (and `kParserBuild`) in `pc-app/src/core.hpp`, run `pc-app/test/run_native.sh`, then
   `pc-app/package.sh`, and publish the new zip on the site (and its entry in `/opt/r6-site/downloads/manifest.json`).
3. Raise `R6_MIN_PARSER` in `/etc/r6-replay.env` to the new version only when you want old uploaders refused. They are
   told "Please update your uploader" and the window shows it.
4. Rounds that failed under an older reader are retried automatically by the new uploader (the server lists them in
   `/v1/known` as `failed`, and a successful `/v1/parsed` replaces the failure and moves it to the end of the feed so
   phones see it). Failed rounds that were sent whole can also be retried on the server with `POST /v1/rounds/{id}/retry`.

## What is checked on the server
Schema version 1; reader version at least `R6_MIN_PARSER` (HTTP 426, message shown by the app); the .rec's SHA-256
(dedupe key, the same one `/v1/known` uses, so nothing already stored is re-uploaded); match id, round 0 to 60, a
plausible timestamp, exactly two teams (one Attack, one Defense) with scores that never go down, 1 to 12 players,
at most 400 events with times on the round clock, a 128 KB body limit. Fields not on the whitelist are dropped. Rules
the real data does **not** support are not enforced: in 16% of real rounds both teams are flagged `won`, some players
have empty names, and some kill targets are not in the player list.

## Known follow-up (not part of this change)
Because 16% of real rounds carry `won: true` for both teams, the phone's win/loss for those rounds can be wrong. Exactly
one team gains a point in every such round, so the score change (`score - startingScore`) says who won. Fixing this in the
app changes Coach numbers, so it is left for a separate change.
