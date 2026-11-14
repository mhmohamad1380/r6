#!/usr/bin/env bash
# Cross-compiles the Windows program on Linux with llvm-mingw: ONE exe holding the window, the console commands
# (R6ReplayUploader.exe <command>), the replay reader (as a resource) and the clip cutter (Windows Media Foundation).
set -euo pipefail
cd "$(dirname "$0")"
TC="${LLVM_MINGW:-$(ls -d "$HOME"/dev/win/llvm-mingw-*/ | head -1)}"
CXX="$TC/bin/x86_64-w64-mingw32-clang++"
WINDRES="$TC/bin/x86_64-w64-mingw32-windres"
mkdir -p build
rm -f build/r6uploader-cli.exe   # the console program is part of the one exe now
FLAGS="-std=c++17 -O2 -Wall -Wextra -static -DUNICODE -D_UNICODE -DWINVER=0x0601 -D_WIN32_WINNT=0x0601 -DR6_ONE_EXE -s"
$WINDRES -O coff -I . -i res/app.rc -o build/app.res.o
$CXX $FLAGS -mwindows -municode src/gui_main.cpp src/cli_main.cpp src/highlights_window.cpp src/core.cpp src/highlights.cpp src/clips.cpp src/live.cpp src/footage.cpp src/platform_win.cpp src/mfcut_win.cpp \
  build/app.res.o -o build/R6ReplayUploader.exe -lwinhttp -lcrypt32 -ladvapi32 -lcomctl32 -lcomdlg32 -lshell32 -lole32 -luuid -lshlwapi -lmfuuid -lwindowscodecs -ld3d11 -ldxgi
ls -l build/*.exe | awk '{printf "%8.1f KB  %s\n", $5/1024, $9}'
