# R6 Coach

A Rainbow Six Siege performance coach for Android (Flutter). It reads your public stats from the
[Arenyze (R6Data) API](https://r6.arenyze.com), scores and analyses them on the device, and tells
you what to work on. There is no backend: the app talks to the API directly.

## What it does

- **Filters**: every number can be shown for All, Ranked, Unranked, Standard or Quick Match, and for
  lifetime or the current season. Unranked is All minus Ranked, so it costs no extra request.
- **Home**: rank, RP and progress to the next division, a performance score, a 7-axis skill radar,
  key numbers, an RP chart you can touch, this week's recap, recent form against your career, and
  the top findings.
- **Matches**: a match log reconstructed from snapshots (add map, party size, mood and notes to each),
  play sessions, RP history with a time-of-day breakdown, and **Replays**: a 0-100 replay score, an
  improvement trend (older matches against newer ones), coaching findings with drills, attack/defense
  split, first-fight impact, clutches, multi-kills, a round-clock histogram, operator and map
  breakdowns and a round-by-round view of each match, all from your own `.rec` replay files.
- **Analytics**: operators (with counters and detail sheets), picks for you, sides and roles, modes,
  maps and teams (solo vs stack, by mood), and a head-to-head compare with another player.
- **Improve**: rule-based findings, each with a practice drill, and measurable goals.
- **Profile**: key and username, API budget, backup and restore, saved history.

## Data and its limits

The API has no match feed. Per-match detail is derived: every refresh stores a snapshot of your
cumulative counters, and the difference between two snapshots is what you played in between. One
match between refreshes gives exact numbers; several are merged and marked as such. Wins and losses
in RP history are inferred from RP going up or down.

The RP ledger keeps every RP reading seen across refreshes, because the API only returns the latest
16. If you play more than 16 ranked games between refreshes, the oldest ones are missed. Match
context (map, party, mood, notes) is entered by the player, since the API has none of it. Because
that history lives only on the device, Profile has a copy and restore backup.

Bundled in the app (no API calls): operator roles and icons (`assets/game_operators.json`),
counter relationships (`assets/counters.json`, from
[r6-operator-counters](https://github.com/BurkusCat/r6-operator-counters), MIT), and rank RP bands
(`assets/ranks.json`, from `/ranks?version=v7`), and the map list (`assets/maps.json`).

## Replay analysis

Siege saves one `.rec` file per round in the `MatchReplay` folder inside the game's install folder (for
example `...\Tom Clancy's Rainbow Six Siege\MatchReplay`, not the Documents folder). Sources disagree on
how many matches it keeps (10 to 12), so files should be copied soon after playing. Two ways to use them, both tested against the real sample replays in
[r6-dissect](https://github.com/redraskal/r6-dissect) (MIT):

| Source | Needs | Kill times | Notes |
|---|---|---|---|
| Upload `.rec` to Arenyze | the file on the phone and a replay credit per file (free plan: 15) | **missing** (all events carry the round's end time) | kill order, killers, victims and headshots match r6-dissect exactly; also gives assists |
| Import r6-dissect JSON | the CLI on a PC: `r6-dissect round.rec -o round.json` | real | exact trades within 5 seconds |

The replay score (`analytics/replay_report.dart`) blends KOST, kills per round, survival, opening
duels, trades, headshots and round results, renormalised over whatever has enough data, with a
penalty for team kills. Like the main score its reference values are assumptions, so it is labelled
provisional and is best used to compare you with yourself. The improvement trend needs 4 saved matches
and 8 rounds in each half before it makes a call.

Without kill times KOST is shown as a minimum (`62%+`) and trades appear as "avenged" (a teammate got
your killer, at any time). Uploads use replay credits, not API requests. Rounds are stored compactly
on the device and included in the backup.

## API budget (free plan: 2,000 calls a month)

| Action | Calls |
|---|---|
| Browsing the app | 0 |
| Refresh (profile + operators) | 2 |
| First time opening Ranked, Standard, Quick Match, or the season view | 1 each |
| Unranked view | 0 (computed from All and Ranked) |
| Compare with a player | 2 |
| Check server usage | 1 |

Auto-refresh only happens when cached data is over 30 minutes old; manual refreshes are blocked for
60 seconds after a fetch. The key is entered in the app and stored on the device only.

## Scoring

`lib/analytics/scoring.dart` blends mechanical (K/D, headshots), tactical (opening duels) and
objective (round wins) components, renormalised over whatever data exists. The reference values and
weights are design assumptions, not measured, so the score is labelled provisional. Missing data is
`null`, never zero. Findings (`insights.dart`) have minimum sample sizes and say what they rest on.

## Build

Needs Flutter 3.47+, JDK 17 and the Android SDK (platform 36, build-tools 36, NDK 28.2, CMake 3.22).

```sh
cd mobile
flutter test                       # 231 tests, including a small-phone layout stress test
flutter build apk --release --target-platform android-arm64 --split-per-abi \
  --obfuscate --split-debug-info=build/symbols
```

Release signing reads `mobile/android/key.properties` (not committed). Without it the build falls
back to the debug key.

`./serve.sh` serves `dist/` on the local network so a phone on the same Wi-Fi can download the APK.

## Layout

```
mobile/lib/
  analytics/   scoring, insights, skills, rank progress, sessions, picks, goals (pure Dart)
  data/        API client, models, snapshots and match diffing, counters, ranks
  core/        theme, widgets, custom charts
  features/    dashboard, matches, analytics, coaching, profile
mobile/test/   unit, data, widget and layout tests (fixtures are real API responses)
docs/          data-sources.md
```

Not affiliated with Ubisoft.
