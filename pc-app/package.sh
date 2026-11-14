#!/usr/bin/env bash
# Builds the Windows programs and packs them, with the replay reader, into ../dist/R6ReplayUploader-windows.zip.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
OUT="$(pwd)/../dist/R6ReplayUploader-windows.zip"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
D="$STAGE/R6ReplayUploader"
mkdir -p "$D/third_party"
cp build/R6ReplayUploader.exe README.txt "$D/"   # one program: the reader and the console commands are inside it
cp third_party/r6-dissect-LICENSE.txt third_party/r6-dissect-unknown-operators.patch "$D/third_party/"
cat > "$D/third_party/READER.txt" <<'EON'
The replay reader built into R6ReplayUploader.exe is r6-dissect from https://github.com/redraskal/r6-dissect (MIT licence, included here),
built from its main branch (e6c2ca8) with a small patch (r6-dissect-unknown-operators.patch) so that a player whose
operator the reader does not know yet no longer stops a whole round from being read.
EON
rm -f "$OUT"
(cd "$STAGE" && zip -qr "$OUT" R6ReplayUploader)
ls -l "$OUT" | awk '{printf "%.1f KB  %s\n", $5/1024, $9}'
