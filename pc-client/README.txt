R6 Replay Uploader
==================

Sends your Rainbow Six Siege replay files (.rec) to your replay server, so the phone app can collect
and analyse them. The game only keeps your last 10 to 12 matches, so keep this running while you play.

WHAT YOU NEED
  - Python 3.8 or newer from python.org. During install, tick "Add python.exe to PATH".
  - The server address and the UPLOAD token (not the phone's read token).

FIRST TIME (about a minute)
  1. Unzip this folder anywhere.
  2. Double-click  setup.bat
     It asks for the server address and the upload token, finds your MatchReplay folder by itself,
     and offers to upload the replays that are already there.
  3. Double-click  start.bat   (leave the window open while you play)

START WITH WINDOWS (optional)
  Double-click  autostart.bat.  Undo it with  remove-autostart.bat.

WHERE ARE THE REPLAYS?
  The game saves them in a folder called MatchReplay inside its install folder, for example
    C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher\games\Tom Clancy's Rainbow Six Siege\MatchReplay
  setup.bat looks in the usual Ubisoft, Steam and other-drive locations. If it cannot find it, it asks
  you to paste the path. Run  python r6_uploader.py discover  to see what it found.

HOW IT BEHAVES
  - Checks the folder every 20 seconds. A file is only uploaded once the game has finished writing it.
  - Each file is uploaded once. If the server is unreachable it keeps the files and retries.
  - Files that are not replays are never sent.
  - It only sends data from this PC to your server. Nothing is deleted from your PC.

COMMANDS (run in a terminal in this folder)
  python r6_uploader.py setup            first-time setup
  python r6_uploader.py                  watch and upload (what start.bat does)
  python r6_uploader.py once             upload what is new, then stop
  python r6_uploader.py discover         show where replays were found
  python r6_uploader.py status           show settings and what has been uploaded
  python r6_uploader.py install-startup  start when you log in
  python r6_uploader.py remove-startup

Settings are stored in  %APPDATA%\r6-replay-uploader\  (config.json holds the token: keep it private).

PROBLEMS
  "does not accept that token"      use the UPLOAD token, not the read token.
  "cannot reach the server"         check the address, and that the server is running.
  No folder found                   paste the MatchReplay path when setup asks.
