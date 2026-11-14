#!/usr/bin/env bash
# Builds core.cpp natively (with Zig) and runs test_core against real local replay servers and the real r6-dissect.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ZIG="${ZIG:-$(ls -d "$HOME"/dev/zig/zig-*/ | head -1)zig}"
OUT=/tmp/claude-1000/native-test
mkdir -p "$OUT"
"$ZIG" c++ -std=c++17 -O1 -g -Wall -Wextra -o "$OUT/test_core" "$HERE/test_core.cpp" "$HERE/../src/core.cpp" "$HERE/platform_posix.cpp"
BACK="$HERE/../../backend"
UP=native-upload-token-aaaaaaaaaaaaaaaa; RD=native-read-token-bbbbbbbbbbbbbbbbbbbb; PORT=18092; PORT2=18096; PORT3=18097
rm -rf "$OUT/data" "$OUT/data2" "$OUT/data3" "$OUT/payloads"
mkdir -p "$OUT/payloads"
cd "$BACK"
R6_DATA_DIR="$OUT/data" UPLOAD_TOKEN=$UP READ_TOKEN=$RD .venv/bin/uvicorn app.server:app --host 127.0.0.1 --port $PORT >"$OUT/server.log" 2>&1 &
SRV=$!
R6_DATA_DIR="$OUT/data2" UPLOAD_TOKEN=$UP READ_TOKEN=$RD .venv/bin/uvicorn app.server:app --host 127.0.0.1 --port $PORT2 >"$OUT/server2.log" 2>&1 &
SRV2=$!
R6_DATA_DIR="$OUT/data3" UPLOAD_TOKEN=$UP READ_TOKEN=$RD .venv/bin/uvicorn app.server:app --host 127.0.0.1 --port $PORT3 >"$OUT/server3.log" 2>&1 &
SRV3=$!
cd - >/dev/null
python3 "$HERE/legacy_proxy.py" 18093 "http://127.0.0.1:$PORT2" legacy & P1=$!
python3 "$HERE/legacy_proxy.py" 18094 "http://127.0.0.1:$PORT" old & P2=$!
python3 "$HERE/legacy_proxy.py" 18095 "http://127.0.0.1:$PORT" strict & P3=$!
trap 'kill $SRV $SRV2 $SRV3 $P1 $P2 $P3 2>/dev/null || true' EXIT
for p in $PORT $PORT2 $PORT3; do for i in $(seq 1 40); do curl -fs "http://127.0.0.1:$p/health" >/dev/null 2>&1 && break; sleep 0.25; done; done
sleep 0.5
R6_PAYLOADS="$OUT/payloads" R6_DISSECT_REAL="$BACK/bin/r6-dissect" R6_URL2="http://127.0.0.1:$PORT2" R6_URL3="http://127.0.0.1:$PORT3" R6_LEGACY_URL="http://127.0.0.1:18093" R6_OLD_URL="http://127.0.0.1:18094" R6_STRICT_URL="http://127.0.0.1:18095" R6_URL="http://127.0.0.1:$PORT" R6_UP=$UP R6_RD=$RD R6_SAMPLES="$BACK/tests/samples" R6_TMP="$OUT/work" "$OUT/test_core"
# The reader on the PC must keep exactly the fields the server's reference trim keeps, on every real sample.
"$BACK/.venv/bin/python" "$HERE/compare_trim.py" "$OUT/payloads" "$BACK" "$BACK/tests/samples"
# The highlight detector: hand-made rounds with known answers, then real replays from two seasons through the real reader.
"$ZIG" c++ -std=c++17 -O1 -g -Wall -Wextra -o "$OUT/test_highlights" "$HERE/test_highlights.cpp" "$HERE/../src/highlights.cpp" "$HERE/../src/core.cpp" "$HERE/platform_posix.cpp"
"$OUT/test_highlights"
"$ZIG" c++ -std=c++17 -O1 -Wall -Wextra -o "$OUT/cli" "$HERE/../src/cli_main.cpp" "$HERE/../src/core.cpp" "$HERE/../src/highlights.cpp" "$HERE/../src/clips.cpp" "$HERE/../src/footage.cpp" "$HERE/platform_posix.cpp"
R6_DISSECT="$BACK/bin/r6-dissect" "$OUT/cli" highlights "$BACK/tests/samples/quick_1.rec" "$BACK/tests/samples/ranked_2.rec" "$BACK/tests/samples/corrupted.rec" --out "$OUT/highlights.json"
python3 -c "import json,sys; h=json.load(open(sys.argv[1]))['highlights']; assert h and all(x['clip']['to'] > x['clip']['from'] for x in h), h; print('highlights.json:', len(h), 'highlights, valid')" "$OUT/highlights.json"
# Recording and clipping: OBS's protocol against a stand-in, the sync arithmetic, and real cutting when R6_FFMPEG is set.
# The stand-in OBS needs the websockets library: use the first Python that has it.
OBS_PY="${OBS_PY:-}"
for py in python3 "$HOME/lend/.venv/bin/python" "$BACK/.venv/bin/python"; do
  [ -n "$OBS_PY" ] && break
  "$py" -c "import websockets" 2>/dev/null && OBS_PY="$py"
done
[ -n "$OBS_PY" ] || { echo "No Python with the websockets library for the stand-in OBS (pip install websockets)"; exit 1; }
"$ZIG" c++ -std=c++17 -O1 -g -Wall -Wextra -o "$OUT/test_clips" "$HERE/test_clips.cpp" "$HERE/../src/clips.cpp" "$HERE/../src/footage.cpp" "$HERE/../src/highlights.cpp" "$HERE/../src/core.cpp" "$HERE/platform_posix.cpp"
"$OBS_PY" "$HERE/fake_obs.py" 18201 hunter2 & O1=$!
"$OBS_PY" "$HERE/fake_obs.py" 18202 & O2=$!
trap 'kill $SRV $SRV2 $SRV3 $P1 $P2 $P3 $O1 $O2 2>/dev/null || true' EXIT
sleep 1.5
R6_OBS_PORT=18201 R6_OBS_OPEN_PORT=18202 R6_TMP="$OUT/work" "$OUT/test_clips"
# The clip workflow from the command line, end to end with the stand-in OBS and real replays (cutting needs R6_FFMPEG).
W="$OUT/clipflow"; rm -rf "$W"; mkdir -p "$W/replays/Match-2026-11-10_20-00" "$W/appdata"
cp "$BACK/tests/samples/ranked_2.rec" "$W/replays/Match-2026-11-10_20-00/R06.rec"
export APPDATA="$W/appdata" R6_DISSECT="$BACK/bin/r6-dissect"
C() { "$OUT/cli" clip "$@" --folder "$W/replays" --port 18202; }
C matches | grep -q "Match-2026-11-10_20-00  (1 rounds)"
C find 1 | tee "$W/find.txt" | grep -q "Rounds to record: 6"
C start 1 | grep -q "Recording."
sleep 1.2
C mark 6 | grep -q "Round 6 timer start marked at 1"
C mark 6 --plant --at 50 | grep -q "Round 6 plant marked at 50"
C stop | grep -q "Saved the recording: C:"
python3 -c "import json,sys,glob; s=json.load(open(glob.glob(sys.argv[1]+'/R6ReplayUploader/clip-sessions/*-*.json')[0])); r=s['rounds']['6']; assert 1 <= r['start'] < 5 and r['plant'] == 50 and s['recording'].endswith('.mkv'), s; print('clip flow: started, marked, stopped:', s['rounds'])" "$W/appdata"
if [ -n "${R6_FFMPEG:-}" ]; then C cut --recording "$W/recording.mkv" --out "$W/clips"; else (C cut --recording "$W/none.mkv" || true) | grep -q "nothing here can cut video" && echo "clip flow: cut explains there is no cutter on Linux without ffmpeg (Windows uses its own; set R6_FFMPEG to cut here)"; fi
# Sending clips: a real server, a real MP4 (built like an encoder writes it, index last), an interrupted upload that must
# resume from the byte the server has, then a second run that sends nothing.
CL="$W/clips-up"; mkdir -p "$CL"
printf 'server=%s\ntoken=%s\nfolder=%s\n' "http://127.0.0.1:$PORT" "$UP" "$W/replays" > "$W/appdata/R6ReplayUploader/config.ini"
"$BACK/.venv/bin/python" -c "
import glob, json, sys, urllib.request
sys.path.insert(0, '$BACK')
from tests.test_highlights import mp4
W, CL, URL, UP = '$W', '$CL', 'http://127.0.0.1:$PORT', '$UP'
hl = json.load(open(glob.glob(W + '/appdata/R6ReplayUploader/clip-sessions/*.highlights.json')[0]))['highlights']
data, _ = mp4(seconds=8.0, scale=500)   # about 15 KB: many pieces of 1000 bytes
clips = []
for i, h in enumerate(hl):
    name = f'clip{i}.mp4'
    open(f'{CL}/{name}', 'wb').write(data)
    open(f'{CL}/clip{i}.jpg', 'wb').write(b'\xff\xd8\xff\xe0' + b'j' * 200)
    clips.append({'id': h['id'], 'file': name, 'thumb': f'clip{i}.jpg', 'start': 1, 'duration': 8.0, 'approx': False})
json.dump({'match_id': hl[0]['match_id'], 'recording': 'r.mkv', 'clips': clips}, open(CL + '/clips.json', 'w'))
# An upload that broke off after 500 bytes:
h = dict(hl[0]); h['video'] = {'size': len(data), 'duration': 8.0}
req = lambda m, u, b, t='application/json': urllib.request.urlopen(urllib.request.Request(URL + u, data=b, method=m, headers={'Authorization': 'Bearer ' + UP, 'Content-Type': t}))
req('POST', '/v1/highlights', json.dumps(h).encode())
req('PUT', f'/v1/highlights/{h[\"id\"]}/video?offset=0', data[:500], 'application/octet-stream')
print('clip upload: prepared', len(clips), 'clip(s), the first one broken off at 500 bytes')
"
C upload --out "$CL" --piece 1000 > "$W/up1.txt"
tail -1 "$W/up1.txt" | grep -q "1 uploaded, 0 already there, 0 failed"
# It continued from the server's 500 bytes: the first piece ends at 1500 bytes (9% of ~16 KB), not 1000 (6%).
head -1 "$W/up1.txt" | grep -q ": 9% sent"
C upload --out "$CL" | tail -1 | grep -q "0 uploaded, 1 already there, 0 failed"
curl -fs -H "Authorization: Bearer $RD" "http://127.0.0.1:$PORT/v1/highlights" | "$BACK/.venv/bin/python" -c "
import json, sys; h = json.load(sys.stdin)['highlights']
assert len(h) == 1 and h[0]['status'] == 'ready' and h[0]['duration'] == 8.0 and h[0]['thumbnailUrl'], h
print('clip upload: resumed and finished; the phone sees it ready, 8.0 s, with a picture; a second run sent nothing')"
# Live clips: the stand-in OBS with a replay buffer (and one without), a controlled clock, the real server.
mkdir -p "$W/obs-replays"
FAKE_OBS_REPLAY_DIR="$W/obs-replays" "$OBS_PY" "$HERE/fake_obs.py" 18203 & O3=$!
FAKE_OBS_NO_BUFFER=1 "$OBS_PY" "$HERE/fake_obs.py" 18204 & O4=$!
trap 'kill $SRV $SRV2 $SRV3 $P1 $P2 $P3 $O1 $O2 $O3 $O4 2>/dev/null || true' EXIT
"$ZIG" c++ -std=c++17 -O1 -g -Wall -Wextra -o "$OUT/test_live" "$HERE/test_live.cpp" "$HERE/../src/live.cpp" "$HERE/../src/footage.cpp" "$HERE/../src/clips.cpp" "$HERE/../src/highlights.cpp" "$HERE/../src/core.cpp" "$HERE/platform_posix.cpp"
sleep 1
R6_OBS_LIVE_PORT=18203 R6_OBS_NOBUF_PORT=18204 R6_URL="http://127.0.0.1:$PORT" R6_UP=$UP R6_RD=$RD R6_TEST_MP4="$CL/clip0.mp4" R6_TMP="$OUT/work" "$OUT/test_live"
