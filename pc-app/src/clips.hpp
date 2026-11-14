// Recording and clipping: talks to OBS to start and stop the recording, remembers when each round's timer started in the
// recording (the player presses a key), and cuts one clip per highlight with ffmpeg.
//
// The game is never touched: the player opens the replay and plays it. OBS records the screen; this program only asks OBS
// to start and stop, and reads how long it has been recording.
#pragma once
#include <filesystem>
#include <functional>
#include <map>
#include <string>
#include <vector>

#include "highlights.hpp"
#include "json.hpp"
#include "recorder.hpp"

namespace clips {

// ---------- OBS (obs-websocket 5, built into OBS 28 and newer) ----------
std::string obs_auth(const std::string& password, const std::string& salt, const std::string& challenge);
std::string base64(const std::string& bytes);

class Obs {
 public:
  ~Obs();
  bool connect(const std::string& host, int port, const std::string& password, std::string& error);
  bool connected() const { return ws_ != nullptr; }
  // Sends one request and waits for its answer. data is a JSON object or empty.
  bool request(const std::string& type, const std::string& data, mini::Json& response, std::string& error, int timeout_ms = 5000);
  bool start_record(std::string& error);
  bool stop_record(std::string& path, std::string& error);   // path: the file OBS wrote
  bool record_time(double& seconds, bool& active, std::string& error);   // how long the current recording has run
  // The replay buffer: OBS keeps the last few minutes in memory; saving writes them to a file.
  bool replay_buffer_active(bool& active, std::string& error);
  bool start_replay_buffer(std::string& error);
  bool save_replay_buffer(std::string& error);
  bool last_replay(std::string& path, std::string& error);   // the file the last save wrote
  void close();

 private:
  void* ws_ = nullptr;
  int next_ = 1;
};

// ---------- syncing rounds to the recording ----------
struct RoundMark {
  double start = -1;   // seconds into the recording when the round timer started counting down from 3:00
  double plant = -1;   // seconds into the recording when the defuser was planted (optional)
};

struct Session {
  std::string match_id, recording;   // recording: the video file of this match's replay (OBS), or the folder of its pieces
  std::map<int, RoundMark> rounds;   // by round number as the game shows it (1-based)
  // Recorded by the built-in recorder: its pieces, and the marks above are wall-clock times instead of times in a file.
  std::vector<rec::Segment> footage;
};

std::string session_json(const Session& s);
bool session_from_json(const std::string& text, Session& s);

// Where a highlight is in the recording.
struct Placed {
  bool ok = false;
  std::string why;            // when not ok
  double start = 0, duration = 0, thumb = 0;   // seconds in the recording
  bool approx = false;        // a post-plant kill without a plant mark
};
Placed place(const hl::Highlight& h, const RoundMark& m, const hl::Options& opt = {});

// ---------- cutting ----------
std::string clip_name(const hl::Highlight& h);   // {match_id}_r{round}_{type}_{id8}.mp4
std::vector<std::string> cut_args(const std::string& recording, const Placed& p, const std::string& out_file, bool hardware_encoder = false);
std::vector<std::string> thumb_args(const std::string& recording, const Placed& p, const std::string& out_file);

struct ClipResult {
  std::string id, file, thumb, error;
  bool ok = false;
  double start = 0, duration = 0;
  bool approx = false;
};
using ClipProgress = std::function<void(int done, int total, const std::string& line)>;
// Cuts every highlight of the session's match with Windows' own video engine, or ffmpeg when that is not possible and
// `ffmpeg` is given (may be empty). Writes the clips, thumbnails and a clips.json index next to them.
std::vector<ClipResult> cut_all(const Session& s, const std::vector<hl::Highlight>& list, const std::string& ffmpeg, const std::string& out_dir, const ClipProgress& progress = nullptr);

// The configured path if it exists, else next to this program, in its ffmpeg folder, or on PATH; empty when there is none.
std::string find_ffmpeg(const std::string& configured = "");

// ---------- sending clips to the replay server (resumable) ----------
struct UploadSummary {
  int sent = 0, already = 0, failed = 0;
  bool stopped = false;      // a problem that stops every upload (server full, wrong token, server gone)
  std::string message;       // why it stopped
};
// Sends every cut clip in `clip_dir` (its clips.json) that the server does not have yet: the details, then the video in
// pieces, then the picture. An interrupted upload continues where the server says it stopped. Remembers what is done in
// clip_dir/uploaded.txt. chunk: bytes per piece.
// With delete_after, each clip is deleted from this PC once the server has all of it, and the folder goes when it is empty.
UploadSummary upload_clips(const std::string& server, const std::string& token, const std::string& clip_dir, const std::vector<hl::Highlight>& list,
                           const ClipProgress& progress = nullptr, size_t chunk = 4 * 1024 * 1024, bool delete_after = false);

// ---------- the workflow the window and the command line share ----------
struct MatchFolder {
  std::filesystem::path dir;
  std::string name;      // the folder's name, which the game sets to the date and time
  int files = 0;
  long long newest = 0;  // newest file time, for sorting
};
std::vector<MatchFolder> match_folders(const std::filesystem::path& root, int max = 20);   // newest first
// Reads one match's rounds through the replay reader. error is set when the reader cannot run at all.
std::vector<mini::Json> read_match(const std::filesystem::path& dir, std::string& error, int* unreadable = nullptr);
std::vector<int> rounds_to_mark(const std::vector<hl::Highlight>& list);   // the rounds that have highlights, in order

std::filesystem::path sessions_dir();
bool load_session(const std::string& match_id, Session& s);
bool save_session(const Session& s);
std::filesystem::path default_clips_dir();   // Videos\R6 Highlights

}  // namespace clips
