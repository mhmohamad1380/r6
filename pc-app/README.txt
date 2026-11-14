R6 Replay Uploader (Windows) 1.7.0
==================================

Sends your Rainbow Six Siege replay files to your replay server, so your phone app can analyse them.
The game only keeps your last 10 to 12 matches, so keep this running while you play.

NO INSTALLER, NO PYTHON
  1. Unzip this folder anywhere (Downloads is fine).
  2. Double-click  R6ReplayUploader.exe
  3. Fill in the form:
       Server address   the address of your replay server
       Upload token     the PC's token (NOT the phone's read token)
       Replay folder    press Find; it looks in the usual Ubisoft and Steam places
  4. Tick "Start with Windows" if you want it to run whenever you log in.
     That copies the program to  %LOCALAPPDATA%\R6ReplayUploader  and adds a Start Menu shortcut,
     so it keeps working if you delete the downloaded copy.
  5. Press "Save and start".

WHAT IS NEW IN 1.7.0: AT MOST 700 MB ON DISK
  Everything the program keeps for clips stays under 700 MB:
    - the recorded minutes: at most 580 MB (the oldest go first), plus the minute being written (about 60 MB);
    - clips waiting to upload when the server cannot be reached: at most 60 MB.
  Clips are deleted from the PC as soon as the server has them (they are on your phone and the server from then on).
  When Siege closes, the recording is deleted.
  Replay clips are now cut as you go too: each moment is cut and uploaded a few seconds after it was played, so a long
  replay session needs no more space than live play. Press Start recording once, F9 at each listed round, Stop at the end.
  Nothing has to be pressed for live clips: recording starts and stops with Siege, and each round is cut when it ends.
  F8 (once per game mode) only makes clip timing exact; until then clips are a little longer.

WHAT IS NEW IN 1.6.0: NO OBS NEEDED
  The program records the screen itself (the built-in recorder), so live clips and replay clips need nothing else.
    - It records only while Siege runs, at 720p and 30 frames per second, with the sound your PC plays.
    - It keeps the last minutes on disk (at most about 640 MB, in %LOCALAPPDATA%\R6ReplayUploader\recording), one
      file per minute, deletes older minutes as it goes, and deletes them all when Siege closes.
    - It uses what Windows offers for screen sharing and your graphics card's video encoder, so the game is not slowed
      much. It never touches the game.
    - Play Siege in Borderless (windowed full screen) display mode: exclusive full screen cannot always be recorded.
  Prefer OBS? Tick "Use OBS instead of the built-in recorder" in the "Clips from replays, and recording settings" window.
  The OBS notes below still apply then.

WHAT IS NEW IN 1.5.0: LIVE CLIPS WHILE YOU PLAY
  Tick "Record live clips while I play" in the main window. From then on, with the program in the tray:
    - When Siege starts, OBS is started (minimised) if it is not running, and its Replay Buffer is turned on:
      OBS keeps the last minutes of your screen in memory.
    - After each round, when the game writes the round's replay, the program finds your best moments in it,
      has OBS save the buffer, cuts each moment out and uploads it. A minute or so later it is in the phone app
      under Matches > Clips. The saved minutes are deleted after cutting.
  Once, in OBS: Tools > WebSocket Server Settings > Enable (copy the password into the Highlights window), and
  Settings > Output > Replay Buffer > Enable, with Maximum Replay Time 600 seconds (10 minutes).
  Make the clips exact: in one round of each game mode (Ranked, Quick Match...), press F8 the moment the round
  timer starts counting down. Until then clips are a little wider, because the program does not yet know how long
  operator selection and the preparation phase take in that mode. You hear a beep when F8 is noted.
  Only moments worth at least 3 points are clipped (a multi-kill, an entry headshot, a round-winning headshot...).
  The program never touches the game: OBS records the screen, and the program reads the replay files.

WHAT IS NEW IN 1.4.0: HIGHLIGHT CLIPS
  Press "Record highlight clips with OBS..." in the main window. It finds your best moments in a match
  (aces, clutches, multi-kills, entries, headshots, round-winning kills) and turns them into video clips.
  You need OBS Studio 28 or newer (free, obsproject.com). In OBS: Tools > WebSocket Server Settings >
  tick "Enable WebSocket server". "Show Connect Info" shows the port and password.
  How it goes:
    1. Connect to OBS.  2. Pick a match and press Find highlights.  3. Press Start recording.
    4. In Siege, open that match's replay and go to the round the window names. Press F9 the moment the
       round timer starts counting down from 3:00 (you hear a beep). Play the round at normal speed.
       If the window asks for it, press F10 when the defuser is planted.
    5. Do the same for each round it lists, then press Stop recording, then Cut clips.
  Clips go to Videos\R6 Highlights\<match>. The program never touches the game: you play the replay,
  OBS records the screen, and F9/F10 only tell this program when a round started.
  Clips are cut with Windows' own video engine: nothing else to install. (ffmpeg is used only if Windows cannot
  read the recording and you have put ffmpeg.exe next to the program.) In OBS, record to MP4 or Hybrid MP4
  (Settings > Output > Recording Format); MKV recordings work on Windows 10 and newer.
  The same is available from a console:  R6ReplayUploader.exe highlights <folder>   and   R6ReplayUploader.exe clip ...

ONE PROGRAM
  R6ReplayUploader.exe is everything: the window, the console commands (run it with a command, for example
  "R6ReplayUploader.exe status"), and the replay reader, which it unpacks to %LOCALAPPDATA%\R6ReplayUploader\reader
  on first use. "R6ReplayUploader.exe licenses" shows the reader's licence.

WHAT IS NEW IN 1.3.0
  - The log shows how each round went as it is read: map, attack or defense, won or lost, your kills, and your operator.
  - Each round also keeps where everyone spawned, overtime and the season, so the phone can show which spawns work for you.
  - Seven more maps are named instead of showing a number.

It then sits in the system tray (bottom-right, near the clock). Closing the window does NOT stop it.
Right-click the tray icon to open it, upload now, pause, or quit.

IF WINDOWS SHOWS "WINDOWS PROTECTED YOUR PC"
  The program is not code-signed (that costs money), so SmartScreen warns about unknown programs.
  Click "More info", then "Run anyway". You can check the file against the SHA-256 on the download page.

WHERE ARE THE REPLAYS?
  In a folder called MatchReplay inside the game's install folder, for example
    C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher\games\Tom Clancy's Rainbow Six Siege\MatchReplay
  If Find cannot locate it, press Browse and choose it. It is created after your first recorded match.

HOW IT BEHAVES
  - Pick the root folder (the one that holds a folder for each match, each with several .rec files).
    Every .rec at any depth below it is considered.
  - Each replay is READ ON YOUR PC by the replay reader built into the program. Only the few KB of
    statistics the apps use are sent (about 3 KB instead of 6 to 12 MB), so uploads take a moment and your upload
    speed no longer matters. The reader runs one replay at a time at low priority. It needs about 150 to 300 MB of
    memory for a second or so and does not disturb the game.
  - Each replay is identified by its content, not its name or place. The program asks the server which replays it
    already has and handles only the ones it does not. A reinstall, a second PC, or a copied or renamed file never
    causes a second upload.
  - It then keeps watching the folder. When the game finishes writing a replay (a few seconds after the last change)
    it is read and sent. A check every 20 seconds is the safety net.
  - When a replay cannot be read (usually a game update added an operator or map the reader does not know yet), the
    log says so with the reason, and the file itself is sent to the server (up to 20 MB) so it can be looked at and
    fixed there. Turn this off with the checkbox in the window if you would rather keep your files private. Either way
    the failure is recorded, and the replay is tried again after the program is updated.
  - If the server says your reader is too old, the window and the log say "Please update your uploader". Download the
    newest version from the website.
  - The window shows a progress bar for the file being sent, and the list below it logs every step with the time:
    what was found, "Reading 2 of 5 on this PC", how small it became, and "Upload complete" or "NOT complete" with the
    reason. "Open log file" shows the same lines kept in %APPDATA%\R6ReplayUploader\uploader.log (about 1 MB, then
    the oldest part is rolled to uploader.log.old).
  - A file that is not in the Siege replay format is never sent. The log says so, with the file's first bytes
    (a real replay starts with the text "dissect", or with 28 B5 2F FD).
  - If the server cannot be reached it keeps the files and retries.
  - Your upload token is stored encrypted for your Windows account (not as plain text).
  - Nothing is ever deleted from your PC.
  - Settings and memory of what was checked are in  %APPDATA%\R6ReplayUploader

WINDOWS VERSIONS
  Versions 1.2.0 and newer need Windows 10 or newer to read replays on the PC (the reader is built with a current toolchain).
  On Windows 7 or 8 the program still runs: it notices the reader cannot start and sends the whole files, the way
  version 1.1.0 did. The website also keeps version 1.1.0 for those systems.

TO REMOVE IT
  Untick "Start with Windows" and press Save, right-click the tray icon and Quit, then delete the
  folders  %LOCALAPPDATA%\R6ReplayUploader  and  %APPDATA%\R6ReplayUploader.

THE REPLAY READER
  The reader is r6-dissect, the open-source reader from github.com/redraskal/r6-dissect (MIT licence in third_party,
  also shown by "R6ReplayUploader.exe licenses"). The program unpacks it to %LOCALAPPDATA%\R6ReplayUploader\reader
  and checks it byte for byte before using it. Some antivirus programs are wary of unsigned programs; if one blocks
  it, allow R6ReplayUploader.exe and that folder.

FOR SCRIPTING
  Run R6ReplayUploader.exe with a command and it works in the console instead of opening the window
  (in a script, use  start /wait R6ReplayUploader.exe ...  so the script waits for it):
    R6ReplayUploader.exe setup --server https://... --token ... [--folder ...]
    R6ReplayUploader.exe once        upload what is new, then stop
    R6ReplayUploader.exe run         keep watching
    R6ReplayUploader.exe discover    show where replays were found
    R6ReplayUploader.exe status
    R6ReplayUploader.exe highlights <folder> [--out highlights.json]
    R6ReplayUploader.exe clip matches | find N | start N | mark ROUND [--plant] | stop | cut

BUILDING IT YOURSELF (Linux, cross-compiled with llvm-mingw): see build.sh. Source is in src/.
