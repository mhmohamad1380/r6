# Data sources: Phase 0 findings

Verified from this machine on 2026-10-30. Update as providers are tested.

## Availability matrix

| Data | Needed for MVP | Source verified? | Notes |
|---|---|---|---|
| Player identity | Yes | No | Needs a provider with a key |
| Current rank / RP | Yes | No | |
| Career statistics | Yes | No | |
| Recent match history | Yes | No | Go/no-go item |
| Map and operator stats | Preferred | No | |
| Per-round events | No | No | |
| Gameplay recordings | No | n/a | Not in MVP |

## Provider reachability

| Provider | Result | Conclusion |
|---|---|---|
| Tracker Network (`r6.tracker.network`, `api.tracker.gg`) | HTTP 403 | Bot-protected and publicly stated to have no R6 API. Not used. |
| Stats.CC (`stats.cc`) | HTTP 403 on site, 400 on `api.stats.cc` | Documents a Siege API that needs a key. Blocked until a key is supplied. |
| Ubisoft (`public-ubiservices.ubi.com`) | HTTP 400 without auth | Needs a logged-in session ticket. Not used: we will not build on Ubisoft's private login flow. |
| R6Data / other keyless hosts | Unreachable (000) | No keyless public R6 stats API verified. |

We do not scrape bot-protected sites or use undocumented endpoints.

## Go/no-go

Architecture decision: no backend. The Flutter app calls the provider directly
and scores on-device. The user pastes their own Stats.CC API key in Settings; it
is stored on the device and never bundled in the APK. Automatic tracking is
undecided until a key is tested. Manual match entry is the fallback.

## Test account

`cyruson1001` (Ubisoft username, supplied by the project owner) is the account
to validate against once a provider is available.
