# R6 Highlights: status and decisions

The plan's goal: find the best moments in replays, record them as clips, upload them, and show them in the phone app.

## Decisions (the plan's open questions)

| Question | Decision | Why |
|---|---|---|
| Existing stack, where the analyzer lives | Windows uploader (`pc-app`, C++). Detector in `pc-app/src/highlights.cpp`, command `r6uploader-cli highlights` | The PC already reads every `.rec` with the bundled r6-dissect, and recording and clipping have to happen on the PC anyway |
| Recording method | OBS WebSocket (v5), with manual recording as a fallback | OBS is free and widely installed. Its WebSocket can start and stop recording and report the file path, without touching the game |
| Storage | Local disk on the VPS, under a quota | 18 GB free. A 20-second 720p clip is about 3 to 6 MB, so a 4 GB quota holds roughly 700 to 1,300 clips |
| Mobile | The existing Flutter app, new Highlights screen | Same server and same token as the replays |

## Phase 1: detection (done)

`r6uploader-cli highlights <folder | .rec | .json>... [--player name,alias] [--min-score N] [--out highlights.json]`

- **Input:** `.rec` files (read with the bundled reader), r6-dissect JSON, the uploader's trimmed rounds, or the server's `/v1/rounds` list.
- **Who you are:** the profile that recorded most of the rounds, or `--player` with any aliases.
- **Types:** ace, clutch (won 1vN), multikill (kills within 15 s), entry (first kill of the round), headshot, round winner (the kill that wiped the other team in a round you won), and plain kill.
- **Scoring:** the plan's table. 1 per kill, +1 for a headshot, +3 per extra kill in the moment, +10 for an ace, +5×N for a won 1vN clutch, +2 for the round-winning kill, +1 for the entry.
- **Merging:** an ace is one moment. A won clutch keeps its kills together. Otherwise kills within 15 s are merged.
- **Clip:** 5 s before the first kill to 3 s after the last. A clutch clip starts when the clutch did.
- **Ids:** each id is derived from the match, round, and first kill, so the same moment always gets the same id. Uploads can be deduplicated by it.

### Differences from the plan's schema

- **No `weapon`:** replays do not record which weapon made a kill.
- **Time:** `round_start_ms` and `round_end_ms` became `clip.from` and `clip.to`, in **seconds since the round timer started counting down from 3:00**. This is the point the recording step syncs to.
- **After a plant, timing is approximate (`clip.approx: true`):**
  - The game times post-plant kills on the 45-second defuser countdown, and the plant event has no usable time of its own.
  - Those kills are placed after the last known moment before the plant.
  - Phase 2 should let the player mark the plant in the video to fix this. In the real data so far, 4 of 110 highlights are affected.

### Verified

- **Hand-made rounds:** 24 tests in `pc-app/test/test_highlights.cpp`, covering ace, won and lost clutch, the defuser clock, team kills, merging, ids, minimum score and the JSON output.
- **Real `.rec` files from season Y8** (`backend/tests/samples`), through the real reader, including a corrupted file that is reported and skipped.
- **313 real rounds from season Y11 on the server:**
  - It produced 110 highlights.
  - All 114 of the player's kills and 46 headshots appear exactly once.
  - Every id is unique.
- **Your data:** no aces or clutches yet. Your best moments are 2K entries and round-winning headshots.

Run all tests with `NO_PROXY=localhost,127.0.0.1 bash pc-app/test/run_native.sh`.

## Phase 2: recording and clipping (built; real-world test pending)

**In the uploader 1.4.0:** the main window has a "Record highlight clips with OBS..." button that opens the Highlights window (`pc-app/src/highlights_window.cpp`). The same workflow is in the console as `r6uploader-cli clip matches | find | start | mark | stop | cut`.

- **OBS:** an obs-websocket 5 client (`pc-app/src/clips.cpp`) that uses StartRecord, StopRecord (for the file path) and GetRecordStatus (for the recording time).
  - It handles password authentication and skips events.
  - It reconnects on its own if OBS restarts.
  - On Windows it uses WinHTTP WebSockets, loaded at run time, so the program still starts on Windows 7. Only the Highlights feature says it needs Windows 8+.
- **Sync:**
  - F9 marks "this round's timer just started" for the next round that has highlights, and you hear a beep.
  - F10 marks the plant, for rounds whose moments come after it. With a plant mark, a post-plant kill is placed exactly: plant + (45 s − the defuser clock).
  - Each falls back to Ctrl+Alt+F9 / Ctrl+Alt+F10 if something else already uses the key.
  - Marks are saved per match in `%APPDATA%\R6ReplayUploader\clip-sessions` and can be undone.
- **Cutting:** bundled-free. The user installs ffmpeg and puts `ffmpeg.exe` next to the uploader, or chooses it in the window.
  - Clips are H.264 + AAC MP4, 720p, `+faststart`, with a 360p JPEG thumbnail at the first kill.
  - If the ffmpeg build has no x264, it falls back to Windows' own H.264 encoder.
  - A `clips.json` index is written next to the clips for Phase 3.
  - Clips go to `Videos\R6 Highlights\<match id>`.

### Tested

- **Stand-in OBS:** 25 checks in `pc-app/test/test_clips.cpp` against `pc-app/test/fake_obs.py`, which speaks obs-websocket 5. They cover:
  - the password answer, which matches the formula computed independently in Python
  - wrong and missing passwords, and OBS's error text being passed on
  - the recording time
  - sync arithmetic, including the plant, clutch starts and clamping
- **The console workflow, end to end:** a real `.rec` through the real reader, then the stand-in OBS for start, F9-equivalent mark, plant mark and stop.

### Not tested yet

- **Real cutting.** It needs an ffmpeg here. The test is written: it builds a 3-minute video, cuts two clips, and checks each is within ±1 s. It runs when `R6_FFMPEG` points at an ffmpeg.
- **The window on real Windows, with real OBS and real Siege.** There is no Windows machine or Wine here.

## Phase 3: server and upload (built and tested; not deployed)

**One Windows program.** `R6ReplayUploader.exe` (10 MB) is everything on the PC:
- the window
- the console commands (`R6ReplayUploader.exe <command>`)
- the replay reader, stored inside the exe, unpacked to `%LOCALAPPDATA%\R6ReplayUploader\reader` and checked byte for byte before use
- the clip cutter, which uses Windows' own Media Foundation, so there's no ffmpeg to install. ffmpeg is only a fallback if one is present.

Media Foundation and WebSockets are loaded at run time, so the exe still starts on Windows 7 and on "N" editions; only the clip features are unavailable there.

**Server** (`backend/app/highlights.py`):

| Method | Path | Token | Purpose |
|---|---|---|---|
| POST | `/v1/highlights` | upload | Create from the detector's JSON plus `video.size` and `video.duration`. It answers how many bytes it already has, so a restart resumes |
| PUT | `/v1/highlights/{id}/video?offset=N` | upload | One piece of at most 8 MB. The wrong offset gives 409 with the right one |
| GET | `/v1/highlights/{id}/upload` | upload | Where an upload stands |
| PUT | `/v1/highlights/{id}/thumbnail` | upload | A JPEG of at most 1 MB |
| GET | `/v1/highlights?after=` | read | The feed, by change number. Deletions come as `{id, deleted}`. Includes storage used and the quota |
| GET | `/v1/highlights/{id}` | read | Details |
| GET | `/v1/highlights/{id}/video`, `/thumbnail` | read, or a share link | Range requests, so players can seek |
| PATCH | `/v1/highlights/{id}` | read | Change `title`; set `visibility` to private or unlisted |
| POST | `/v1/highlights/{id}/share` | read | A signed link that plays without a token for 7 days. Making the clip private changes its key and ends every link |
| DELETE | `/v1/highlights/{id}` | read | Delete |

- **Every finished upload is checked to be an MP4** and rewritten with its index first ("fast start"). Windows' encoder puts the index last, and phones need it first to start playing early.
- **Limits:** a 4 GB quota (`R6_CLIPS_MAX_MB`) and 150 MB per clip (`R6_MAX_CLIP_MB`). nginx needs no change: it already allows up to 1 GB per request for r6.

**Uploader:** "Cut and upload" sends the clips straight after cutting, in 4 MB pieces.
- A lost connection is retried with growing waits and continues from the byte the server has.
- Finished clips are remembered and never sent twice.
- The console has the same as `clip upload`.

### Tested

- 26 server tests:
  - fast start with 32- and 64-bit offsets, where every frame stays reachable
  - non-MP4 files refused
  - resuming an upload, and refusing more bytes than announced
  - token roles, field checks and the quota
  - range playback and thumbnails
  - share links: tampered, expired and revoked
  - rename, delete, and paging through the feed
- End to end with a real server: an upload broken off at 500 bytes continues from there, and a second run sends nothing.
- All 138 server tests and 178 uploader checks pass.

### Not tested yet

The Windows-only parts have never run on Windows: the Media Foundation cutter, the window, the hotkeys and the real OBS. That needs a session on your PC.

## Phase 4: phone (built, tested, released as app 1.8.0)

**Where:** Matches > **Clips**, next to Replays. The home screen also gets a "Your latest clip" card.

**The list** (`mobile/lib/features/clips/clips.dart`):
- **Cards:** a thumbnail with the clip length, a type badge (Ace, Clutch 1v2, 3K, Entry kill, Headshot), the score, a "link on" icon, and round, operator and date.
- **Filters:** by type; only types that have clips are shown.
- **Sorting:** best first or newest first.
- **Storage:** server storage used, against the quota.
- **Empty states:** each says what to do next (connect to the server, or record clips on the PC).

**Player:**
- **Playback:** streams with seeking, and has a full-screen landscape mode.
- **Details:** what happened (each kill, its time, headshots, the victim's operator), plus a note when post-plant timing is approximate.
- **Actions:** copy share link, rename, make private, and delete with confirmation.

**Sync:** clips come with the normal replay sync (`/v1/highlights?after=`) and are cached, so the list shows offline. Thumbnails need a connection.

**Not done:** push notifications, and saving a clip to the phone's gallery. Sharing is by link instead.

**Tests:** `mobile/test/clips_test.dart`, 9 tests:
- syncing, including paging, edits and deletions, and the offline cache
- rename, share, make private and delete calls
- switching servers
- the list at 320, 360 (×1.3 text) and 411 dp with no overflow
- the player's actions

All 264 app tests pass.

## Live (2026-11-10)

- **Server:** `/v1/highlights` at r6.cyruson.ir, with a 4 GB clip quota. Checked live through nginx: an upload in two pieces became ready (6.0 s), a range request returned 206, a share link played without a token, playback without a token or link got 401, and after deleting, the link returned 404.
- **Downloads:** Android 1.8.0 and Windows 1.4.0 (one exe), both checked byte for byte against the builds.
- **Not yet run on real hardware:** the Windows clip window, cutter and hotkeys with OBS, and video playback on a phone with a real clip.

## Live clips while playing (uploader 1.5.0, live 2026-11-10)

**What it does:** with "Record live clips while I play" ticked, the uploader works in the background (`pc-app/src/live.cpp`):
1. **While Siege runs** (it checks the process list for RainbowSix*.exe), it starts OBS minimised if it is installed and closed, and keeps OBS's **Replay Buffer** on. OBS holds the last 10 minutes in memory.
2. **When a round's replay is read**, about 15 s after the round ends, it finds the player's moments worth at least 3 points.
3. If there are any, it has OBS save the buffer at once, and queues the cut.
4. **A worker places each moment in the saved video.** The video ends when it was saved, and is as long as Media Foundation says. The round's start time comes from the replay's UTC timestamp. The moment's time comes from the round timer, plus the gap between the round's start and its timer starting.
5. It cuts the clip, uploads it (failed uploads are retried after the next round), and deletes the saved minutes.

**Calibration:** the gap between the round's start and its timer starting is not in the replay.
- It is learned per game mode from one press of **F8** when a round's timer starts, and saved in `config.ini` as `live_offsets`.
- Until then it is guessed (60 s, or 45 s for Quick Match), and the clips are padded wider (12 s before, 6 s after).

**Tests:** 29 checks in `pc-app/test/test_live.cpp`, run against the stand-in OBS (now with a replay buffer, plus one without) and a real server, using a controlled clock. They cover:
- the placement arithmetic, both before and after calibration
- that old and small rounds don't save the buffer
- moments older than the buffer, which are skipped with advice
- OBS without a replay buffer
- the clips reaching the phone's feed

**Not tested yet:**
- on Windows with real OBS and Siege
- what the replay's timestamp really marks; calibration absorbs this, so it only matters for the first uncalibrated round per mode
- whether OBS's saved video really ends at the moment of saving. If it doesn't, calibration absorbs the difference as long as it stays steady

## Built-in recorder: no OBS (uploader 1.6.0, built 2026-11-11, not published yet)

`pc-app/src/mfcut_win.cpp` (namespace `rec`), with the shared, portable lookup in `pc-app/src/footage.cpp`. It records the screen and sound itself, so neither live nor replay clips need OBS. OBS remains an option ("Use OBS instead of the built-in recorder").

**Picture:**
- DXGI Desktop Duplication of the primary screen, the same method screen-sharing apps use.
- The graphics card's video processor scales it to 720p and converts it to NV12. If that is unavailable, the conversion happens on the processor instead.
- 30 fps, timed by the performance counter.

**Sound:** WASAPI loopback of the default output, converted to 16-bit stereo at 44.1 or 48 kHz. Silence is filled in when nothing plays, so picture and sound stay in step.

**Files:**
- One MP4 per minute (H.264 at 8 Mbit/s, and AAC), written with the hardware encoder when there is one.
- The last 12 minutes are kept in `%LOCALAPPDATA%\R6ReplayUploader\recording`; older minutes are deleted as it goes.
- `flush()` finishes the current minute at once, so a round that just ended can be cut.

**Live clips:** recording starts and stops with Siege. A moment is found by wall-clock time in the minutes, and one that crosses a minute is joined from two files (`cut_parts`).

**Replay clips:**
- F9 and F10 marks are wall-clock times.
- When recording stops, the session's minutes are moved into `clip-sessions/<match>-recording`, so the rolling buffer can't delete them before they are cut.

**Tests:**
- A stand-in recorder with known wall times: 14 more live checks, including a moment crossing a minute boundary and one older than the recording.
- The piece lookup (gaps, edges), and saving and cutting a session with recorded minutes.
- 255 Windows-side checks in all, plus 264 app tests and 33 site tests, all pass.

**Never run on Windows:** capture, encoding and sound. The first session on your PC is the test. Siege should be in Borderless mode.

## Milestones

| # | Milestone | State |
|---|---|---|
| M1 | Detection: replays to ranked highlights JSON | Done |
| M2 | Clipping: OBS + cutting, MP4 and thumbnail | Built (Windows cuts with Media Foundation); needs a test on Windows with OBS |
| M3 | Upload: desktop to server, resumable | Done, live |
| M4 | Mobile: feed and player | Done, app 1.8.0 live |
| M5 | Polish | One exe; no ffmpeg needed; fast-start on the server; site updated. Next: a first real session on Windows with OBS |
